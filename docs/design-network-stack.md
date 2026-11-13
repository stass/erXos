# erXos's TCP/IP stack

The network service runs erXos's own TCP/IP stack, written in Erlang, in
the network domain ([design.md](design.md#networking)). This document is
the stack's design: which process owns which state, how a packet travels
from the network driver to a socket's owner and back, how the protocols'
decisions are taken from FreeBSD, what a domain may do with its grant of
the service, what Erlang programs and POSIX programs see, and how the
stack is checked against FreeBSD's behaviour and stock OTP's.

Decisions every reader needs:

* **FreeBSD's decisions, translated; not its structure.** Every protocol
  decision comes from FreeBSD's default TCP stack, the function block
  named "freebsd", with CUBIC as the default congestion control, at the
  pinned commit `975e3605ebb1` of FreeBSD 16.0-CURRENT (`main-n285245`),
  the kernel the FreeBSD test host runs. The translation was read from
  FreeBSD 15.1 (tag `release/15.1.0-p6`, commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`); of what FreeBSD changed
  between that release and the pin, the changes the wire or an
  interoperating peer can see and the fixes of real bugs are ported, and
  nothing is re-translated to match the pin line by line. The line
  references in this document are to `release/15.1.0-p6`. Each Erlang
  function that translates a FreeBSD
  decision names the FreeBSD function it comes from. FreeBSD's locks,
  mbufs, epochs, virtual-stack indirection, sysctl registration and
  BlackBox logging are not translated: the construction below leaves them
  nothing to do. Where FreeBSD offers a knob, the stack does what
  FreeBSD's default does, unless this document states a departure and its
  reason.
* **One owner for each piece of state, one pure step for each owner.**
  Five kinds of process own all of the stack's state: an interface
  process per network interface, a connection process per TCP
  connection, a listener per listening socket, a datagram socket per UDP
  socket, and a grant process per client domain. Each decides by a pure
  function `step(Event, State, Context) -> {State, Actions}` and then
  performs the actions. Nothing else writes that state.
* **A socket is two processes, one on each side of the lane.** In the
  network domain the connection process holds the TCP state, and the
  interface process hands it segments, one local message per batch of
  frames. In the program's own domain a socket process, the shape of
  stock OTP's `gen_tcp_socket`, presents the stream as `gen_tcp` does:
  active modes, packet framing, `recv`. The socket process alone talks to
  the connection and alone sends the program the socket's messages, so
  stock `receive {tcp, S, Data}` code works in every domain. There is no
  process per layer.
* **Deadlines, not timers.** A connection's timers are deadlines in its
  state, as FreeBSD 15 keeps them, and the process holds one Erlang timer
  at the earliest. A timer message is a hint to look at the clock, never
  an event in itself, so a late, early or duplicate one changes nothing.
* **Every packet queue is credited.** A process that hands packets to
  another does so only against a credit the receiver published. Every
  queue between the driver, the interface process and the sockets is
  bounded, and a refused hand-over is a drop counted where it happens.
* **Sequence numbers are plain integers.** A connection keeps sequence
  numbers and timestamps unwrapped, as unbounded integers, so ordinary
  `<` and `+` are correct everywhere in the protocol code. The only
  modular arithmetic is the conversion at the wire, in one module.
* **A domain's grant is a process of the network domain.** It is the
  domain's facet of the network service, holds the domain's limits and
  creates its sockets. Each socket acts for that domain alone and charges
  its work, on requests and on packets alike, to the grant's account.
* **Loss detection and congestion control are behaviours from the
  start,** `erx_tcp_loss` and `erx_tcp_cc`, mirroring FreeBSD's function
  block and its `struct cc_algo`, over one record of sent data that
  serves both FreeBSD's RFC 6675 recovery and RACK-TLP. The default
  stack is the reference; RACK-TLP and BBR are
  left for later, each a module behind these seams.
* **A run is the unit of TCP work, and C does only work that rides on
  bytes.** Output emits runs, segments that share one header, and the
  copy into each medium cuts a run into frames as it copies; the
  interface merges each received batch's in-order segments of one flow
  before it classifies them. A segment is a run of one, and the step it
  pays alone is lean
  ([design-network-fastpath.md](design-network-fastpath.md)). Besides
  the cut and the merge, C does the Internet checksum and the SipHash
  keyed hash, per-byte primitives of the runtime. Every TCP decision is
  Erlang's; whether one needs native code is measured on this stack, on
  erXos's kernel.
* **The stack is an ordinary OTP application.** `erx_net` runs
  unchanged on stock OTP 29.1.2, outside erXos as well as on a
  development host, exchanging Ethernet frames through a pipe driver with
  real peers or with a test, under the real clock or a virtual one. Four
  seams separate it from erXos: the driver's transport, the clock with
  the entropy source, the per-byte primitives and the runtime's calls for
  grants. Each has an erXos implementation and a portable one, chosen by
  configuration, and the stack's own modules name neither
  ([The effect layer](#the-effect-layer)).

## Contents

1. [Context](#context)
2. [Requirements](#requirements)
3. [The construction](#the-construction)
4. [Processes and the packet path](#processes-and-the-packet-path)
5. [The TCP core](#the-tcp-core)
6. [IP, neighbours and UDP](#ip-neighbours-and-udp)
7. [The effect layer](#the-effect-layer)
8. [Modules and provenance](#modules-and-provenance)
9. [Authority and admission](#authority-and-admission)
10. [The interface towards Erlang programs](#the-interface-towards-erlang-programs)
11. [The interface towards POSIX programs](#the-interface-towards-posix-programs)
12. [Untrusted input](#untrusted-input)
13. [Concurrency and failure](#concurrency-and-failure)
14. [Refusals and error results](#refusals-and-error-results)
15. [Where C is used, and what is measured](#where-c-is-used-and-what-is-measured)
16. [Verification](#verification)
17. [Scope](#scope)
18. [Decisions](#decisions)
19. [Alternatives considered](#alternatives-considered)
20. [References](#references)

## Context

### What the stack matches

Three things fix the stack's behaviour.

* **The protocols, as FreeBSD implements them at the pin.** The owner
  chose to "take freebsd stack as a reference and translate logic to
  erlang ... so we don't discover problems from scratch", and agreed to
  translate FreeBSD's decisions, not its structure, against one pinned
  tree ([Decisions](#decisions), 9).
  FreeBSD's networking code is BSD-licensed, maintained, tested by
  FreeBSD's own TCP test suite, and is the UNIX that erXos follows where
  UNIX systems differ (CLAUDE.md, principle 5).
* **The Erlang API, as stock OTP 29.1.2 behaves.** `gen_tcp`, `gen_udp`
  and `inet` behave as stock does, as OTP's own suites check, run on
  erXos and on stock and compared case by case
  ([design-runtime.md](design-runtime.md#erlang-visible-behaviour)).
* **erXos's architecture.** The stack runs in the network domain, every
  connection is a process, per-packet work is Erlang and per-byte work is
  C, a received frame is copied once out of its device buffer, traffic
  that names no client spends a finite per-interface budget, and work for
  a client is bounded by that client's facet and lane
  ([design.md](design.md#networking)).

### Why FreeBSD's default stack

FreeBSD 15.1 builds three TCP stacks. The default, named "freebsd"
(`sys/netinet/tcp_subr.c:351-352`, installed as the default at
`tcp_subr.c:365`), has `tcp_default_output` (`tcp_output.c:186`) as its
output routine and `tcp_do_segment` (`tcp_input.c:1511`) as its segment
handler. Its default congestion control is CUBIC (`cc/cc.c:80-83`). RACK
and BBR are built as modules that a GENERIC kernel does not load; both
depend on the high-precision timer system (`tcp_stacks/rack.c:24671`,
`tcp_stacks/bbr.c:14824`), and each replaces the whole input and output
path rather than plugging into the default stack. BBR is Netflix's port
of BBR version 1.

Raw line counts at the pinned commit, by `wc -l`:

| Part | Files | Lines |
| --- | --- | --- |
| default stack, core | `tcp_input.c` 4,191, `tcp_output.c` 2,179, `tcp_subr.c` 5,056, `tcp_usrreq.c` 3,015, `tcp_syncache.c` 2,587, `tcp_sack.c` 1,200, `tcp_reass.c` 1,115, `tcp_timer.c` 973, `tcp_timewait.c` 354, `tcp_seq.h` 100 | 20,770 |
| congestion control | `cc/cc.c` 753, `cc/cc_newreno.c` 602, `cc/cc_cubic.c` 726 | 2,081 |
| RACK and BBR | `tcp_stacks/rack.c` 24,673, `tcp_stacks/bbr.c` 14,824, and the timer system they share, `tcp_hpts.c` 2,137 (in `sys/netinet`, not `tcp_stacks`) | 41,634 |

The default stack is the reference: it is the stack FreeBSD runs and
FreeBSD's TCP test suite checks, its congestion-control seam is small,
and RACK and BBR are each a second TCP implementation that needs the
high-precision timer system and its own input path before it sends a
byte. Most of the default stack's volume is locking, mbuf handling,
sysctls, logging and kernel plumbing; what is translated is its
decisions. RACK is deferred: the default stack is the
reference, and RACK-TLP and BBR come later behind its seams. RACK-TLP
(RFC 8985) is then a loss-detection module over the send log, read from
`rack.c` for its logic and needing nothing outside its module; BBR is a
congestion-control module, which also needs pacing in output. Neither is
part of the stack this document designs
([Loss detection and congestion control](#loss-detection-and-congestion-control)).

### What a naive Erlang stack gets wrong

The aloha stack (github.com/yamt/aloha, commit `0aa96f14`, BSD-2-Clause)
was assessed as a base and rejected. Its faults are a checklist of what an
Erlang stack gets wrong when it starts from the RFC state diagram, and
each row names what in this design removes the fault.

| Fault in aloha | What prevents it here |
| --- | --- |
| one malformed frame crashes the interface process, which runs unsupervised | total decoders proved by fuzzing; the driver parses no frame; a raising step in the interface process drops the frame and keeps the state ([Concurrency and failure](#concurrency-and-failure)) |
| initial sequence number 0 | RFC 6528 in `erx_tcp_isn`, from FreeBSD's `tcp_new_isn` |
| any in-window RST resets the connection | RFC 5961 checks, from `tcp_input.c`, unconditional |
| a process per SYN, never expired | the syncache in the interface process, bounded, with SYN cookies ([Connection setup](#connection-setup)) |
| `rcv_nxt = Seq + 1` without wrapping; window arithmetic across the wrap | unwrapped sequence numbers ([The construction](#the-construction)) |
| any ACK overwrites the send window | the SND.WL1/SND.WL2 rule, translated |
| no congestion control, go-back-N, dropped out-of-order data | the default stack's loss detection, CUBIC, the reassembly queue |
| wall-clock RTT samples | the monotonic clock, passed to pure functions as an argument |
| a payload copied four times on transmit, checksum in Erlang | headers and payload kept apart until the device NIF's one copy, which also computes the checksum ([Checksums in the copy](#checksums-in-the-copy)) |
| unbounded neighbour cache and pending queue, unsolicited replies accepted | bounded neighbour tables in the interface process, FreeBSD's acceptance rules |

### What the stack stands on

The stack is two layers in one application, `erx_net`: the pure core,
the modules marked P in [Modules](#modules), which decide, and the
effect layer, the processes marked E, which read inputs, call the core's
steps and carry out their actions. Beneath them:

* **The per-byte primitives** `erx_bytes:inet_csum/2`,
  `inet_csum_update/3` and `siphash24/2`, BIFs of erXos's ERTS over
  portable C, and `erx_bytes:entropy/1`, Erlang's one entry to the
  kernel's generator, `erx_entropy_read`
  ([design-runtime.md](design-runtime.md#per-byte-primitives),
  [design.md](design.md#decisions)). Their C is `erx_net`'s own, in its
  `c_src/`. Outside erXos, the module of the same name in `erx_net`'s
  `portable/` directory loads that same C as a NIF library, and
  `entropy/1` there is the host's generator
  ([Two places, four seams](#two-places-four-seams)).
* **The device NIF**: `erx_device:post/4` takes one to four binary
  segments of one request and copies them into a pool buffer, and
  `erx_device:complete/2` returns up to 64 KiB of completed buffers as
  fresh binaries per call
  ([design-runtime.md](design-runtime.md#the-device-nif));
  `post_frame/5`, the network's form of posting, cuts a run into frames
  and finishes their checksums, and a delayed frame's, in that copy, and
  `complete/3` computes each frame's network sum in it
  ([Checksums in the copy](#checksums-in-the-copy)).
* **OTP's dispatch on module sockets.** `gen_tcp`, `gen_udp` and `inet`
  dispatch every call on a socket of the form `{'$inet', Module, Handle}`
  to `Module` (the `module_socket` macro, `otp/lib/kernel/src/gen_tcp.erl:261`
  and `otp/lib/kernel/src/inet.erl:469`), and `inet:gen_tcp_module/1` and
  `inet:gen_udp_module/1` choose the module from the `inet_backend`
  setting (`inet.erl:3289-3300`, `inet.erl:3409-3420`).
* **The runtime drops OTP's `socket` and `net` NIFs**
  ([design-runtime.md](design-runtime.md)), so in the network domain
  and in every client domain this stack is the only network
  implementation.

## Requirements

* **N1. Behaviour.** On the wire, the stack behaves as FreeBSD's
  default stack at the pin with its default settings, except where this
  document states a departure. The aim is a stack that interoperates as
  FreeBSD's does, not one equivalent to it line by line: every
  difference found by the oracles is a bug, a documented departure with
  a test, a FreeBSD bug recorded as such, or, since the oracle host
  tracks -CURRENT, a change FreeBSD made after the pin, recorded with its
  commit ([Decisions](#decisions), 9).
* **N2. API.** `gen_tcp`, `gen_udp` and `inet` behave as stock OTP 29.1.2
  on the host, as OTP's suites check; a POSIX program's sockets behave as
  on FreeBSD within the POSIX layer's tiers.
* **N3. Every connection is a process** of the network domain, which the
  inspector shows and the tracer can follow.
* **N4. Hostile packets.** No packet, sequence of packets or rate of
  packets crashes an interface, grows memory without a bound, creates an
  atom, or makes the stack do more than fail or drop traffic
  ([design.md](design.md#threat-model), the network peer's row).
* **N5. Bounded per client.** What one domain can make the network domain
  hold or spend is bounded by its grant; traffic that names no client
  spends a finite per-interface budget, and control traffic keeps making
  progress while excess is dropped, up to the frame rate one interface
  process can decode ([Residuals](#residuals)).
* **N6. Failure is local.** A malformed frame never kills an interface; a
  failed connection ends alone; a failed interface ends no connection; a
  network domain killed under load restarts, ending only its connections.
* **N7. Few hops, few copies.** A received segment reaches its connection
  through two local messages per batch, and a transmitted one reaches the
  driver through one; inside the network domain a frame is copied once on
  receive and once on transmit, both in the device NIF, and those copies
  compute the Internet checksum, so each byte of a TCP segment is read
  once on each path ([Checksums in the copy](#checksums-in-the-copy)). A
  delivery takes one local message more, in the owner's domain, from the
  socket process to the owner, and a call one local round trip, to the
  socket process; a stream's bytes cross between the domains with no
  reply in either direction.
* **N8. Functional core.** Every protocol decision is a pure function,
  tested on the host, and protocol state machines are explored
  exhaustively over an abstract alphabet to a stated depth.
* **N9. Seams.** Loss detection and congestion control are replaceable
  per connection without touching the connection's other code.
* **N10. Provenance.** Every module that translates FreeBSD code carries
  the FreeBSD files' copyright notices and licence, and names the
  functions it translates, at the pinned commit.
* **N11. Testable on a host.** Every module of `erx_net` but the erXos
  implementations of its seams runs unchanged on stock OTP 29.1.2 on a
  development host, the processes included, so the whole stack is tested
  there against real peers and packet scripts before and beside the
  network domain on QEMU.
* **N12. Usable without erXos.** `erx_net` is an ordinary OTP
  application, with its own app file, that runs on stock OTP outside
  erXos, needing only `kernel` and `stdlib`, and outside erXos `crypto`
  for its portable entropy source; the client
  backends are a second such application, `erx_net_client`. What is
  erXos's is the erXos implementation of each seam, chosen by
  configuration, and no other module names it
  ([Two places, four seams](#two-places-four-seams)). `erlang/apps/erx_net`
  is self-contained, so that it can be released on its own: its licence
  notices, erXos's and `NOTICE-freebsd`, and its host tests are inside
  the app directory, the tests run on stock OTP from the app alone, and
  nothing in its source refers to a path elsewhere in the erXos tree.

## The construction

The stack rests on four rules. Each removes a class of mechanism that
FreeBSD or a naive Erlang stack needs, and the rest of the document
follows from them.

### One owner, one step

Every piece of protocol state belongs to exactly one process:

| Owner | Process | State it owns |
| --- | --- | --- |
| an interface | `erx_net_if`, one per network interface | its addresses, its neighbour cache (ARP and IPv6 neighbour discovery) and the packets waiting on it, its routers and prefixes, its IP reassembly queues, its share of the syncache, its rate limiters |
| a TCP connection | `erx_tcp_conn` | the connection's control block (FreeBSD's `struct tcpcb`), its send and receive buffers, its reassembly queue, its socket process and the credit that process granted |
| a listening socket | `erx_tcp_listen` | its accept queue and its waiting `accept` requests |
| a UDP socket | `erx_udp_sock` | its receive queue, its options, its socket process and the credit that process granted |
| an ICMP echo socket | `erx_icmp_sock` | its echo identifier, its queue of echo replies, its owner |
| a socket as a program sees it | the socket process, `erx_gen_tcp` or `erx_gen_udp`, in the owner's domain ([The socket process](#the-socket-process)) | its owner, its active mode and presentation options, the bytes or datagrams it holds, the credit it granted, its requests in flight |
| a client domain's grant | `erx_net_grant` | the domain's limits, its account, its sockets' buffer reservations |

Each owner is a loop around one pure function of its kind:

```erlang
step(Event, State, Context) -> {State, [Action]}
```

`Context` carries everything from outside the process the decision needs:
the current monotonic time, the credit the transmit path offers, the
path's MTU and whether it has a route ([Framing](#framing)). The function reads no
clock, no ETS table, no process and no entropy source; it returns the
next state and a list of actions from a closed vocabulary (transmit
these frames, deliver these bytes, reply to this caller, end). The loop
reads the context, calls the step, performs the actions in order and
arms its one timer. The step
never sends, so an exception inside it leaves the state exactly as it was
before the event.

**Random values are state, not context.** Several decisions need random
values: the IPv4 identification of a non-atomic datagram and the IPv6
fragment identification, the starting point of the ephemeral port
search, an active open's IPv6 flow label, the delays and nonces of
neighbour discovery, duplicate address detection and MLD reports, the
reachable time, the jitter of the ICMP and RST rate limits, temporary
interface identifiers, and the DHCP client's transaction id and
retransmission jitter. FreeBSD calls `arc4random` at each of these
points. The stack instead keeps a random generator in the state of every
owner, a pure value of `erx_net_rand`:

```erlang
-opaque gen().                    % {Key :: <<_:128>>, Counter}
new(<<_:128>>) -> gen().
bytes(N, gen()) -> {binary(), gen()}.
uniform(Range, gen()) -> {0..Range-1, gen()}.
split(gen()) -> {Child :: gen(), gen()}.
```

Block `I` of a generator's stream is `erx_bytes:siphash24(Key,
<<(Counter + I):64>>)`, eight bytes, and every draw advances the counter
past the blocks it used, so no block is given twice. `uniform/2` reduces
one block modulo `Range`, a bias below `Range / 2^64`. `split/1` takes
the parent's next two blocks, 16 bytes, as the child's key and advances
the parent's counter past them: the child is `new/1` of those bytes, its
counter starting at zero, and no block of the parent's stream is both
drawn and used as a key, so no two children share a key. The stream is SipHash-2-4
used as a keyed pseudorandom function over a counter: its outputs reveal
neither the key nor later outputs, and it rests on the same assumption as
the initial sequence numbers and SYN cookies, which already depend on
SipHash keeping its key secret. A generator past 2^64 blocks raises,
which no owner reaches. OTP's `rand` is not used: its algorithms are
not cryptographic, and an observer of a few outputs can predict the
rest.

A step draws from the generator in its state and returns the advanced
generator with the rest of its state. So no step needs a random value it
was not given, and the context needs no random bytes: a draw never runs
out, a step that raises leaves the generator as it was, and a step's
result is a function of its event, state and context alone. A test fixes
a key and gets the same stream on every run; the host runners of the
packet scripts and the explorer do.

The keys come from the entropy source at the edge. Every owner a
supervisor starts (an interface process, a grant, `erx_dhcp4`) draws its
16-byte key with `erx_net_clock:entropy/1` in its initialisation. In the
network domain that is `erx_bytes:entropy/1`, the domain's one call into
the kernel's generator (`erx_entropy_read`,
[design-kernel.md](design-kernel.md#interrupts-time-and-entropy)); in a
virtual-time test run it is the test clock's seeded generator
([The clock](#the-clock)). Every owner the stack spawns (a connection, a
listener, a datagram socket) receives in its initial state a child split
from its spawner's generator, so a connection costs no kernel call for
its randomness, and a key seen in one owner's state predicts nothing of
its parent's or another owner's. `erx_net_tables` draws the stack-wide
secrets, for initial sequence numbers, timestamp offsets and SYN
cookies, from the same call. A failed read raises in the owner's
initialisation, so a process that cannot draw its key does not start,
as ERTS refuses to start without its reference key
([design-runtime.md](design-runtime.md#unguessable-references)), and no
owner falls back to another source; its supervisor restarts it. On
erXos's kernel the generator is ready before any domain runs, so a read
fails only on the stopgap, when its backend cannot reach its generator
service. In
deterministic mode the kernel's generator is fixed, so the whole stack's
random values repeat from boot to boot.

Because no state has two writers, there are no locks, no reference counts
and no epochs: a connection's end is its process's exit, and a pid that
names a dead process names nothing ([design-domains.md](design-domains.md#invariants), D1).
Other processes read only what an owner publishes in an ETS table: the
demultiplexing entries, each held by one socket, and the interfaces,
addresses, routes and neighbour entries, each written by its interface
([What owners publish](#what-owners-publish)).

### Deadlines, not timers

FreeBSD 15 keeps an array of deadlines in each control block and one
callout set at the earliest of them (`tcp_timer_next`, `tcp_timer_enter`
and `tcp_timer_activate`, `tcp_timer.c:854-935`). The stack keeps the same
shape. A connection's state holds its deadlines (retransmission or
persist, keepalive, delayed ACK, 2MSL, which also ends FIN-WAIT-2, and
whatever the loss-detection module asks for);
`erx_tcp:next_deadline/1` returns the earliest. After
every step the process makes sure one hint is armed no later than that
deadline, through `erx_net_clock:arm/1` ([The clock](#the-clock)): it
arms one when none is outstanding or the deadline is earlier than the
outstanding one, and otherwise leaves the outstanding one, which may then
arrive early. When a hint arrives, the process calls `step({expired, Now}, ...)`,
which runs every deadline at or before `Now` and does nothing for the
rest.

A timer message carries no meaning of its own, so there is nothing to
cancel and no stale message to recognise: restarting the retransmission
timer on an ACK is a field update, and a timer that fires early is a
look at the clock that finds nothing due. FreeBSD's rule that the
retransmission and persist timers are never both armed becomes a type:
`send_timer :: none | {rexmt, Deadline} | {persist, Deadline}`. The
count of timeouts in a row, `t_rxtshift`, is a field of its own,
`rxtshift`, since FreeBSD keeps it when the timer stops on an ACK and
resets it only on an RTT sample, an undone spurious timeout or the end
of persist.
The interface process keeps its deadlines (neighbour retries, reassembly
lifetimes, syncache retransmissions, router and prefix lifetimes) the
same way.

### Credited queues

ERTS bounds no mailbox, and a stack under attack is a set of mailboxes
that someone else fills. So no stack process hands packets to another
except through `erx_net_credit`:

* The receiver creates an `atomics` counter (for a connection the
  interface starts, the interface creates it) and publishes it with its pid:
  the driver in its interface record, a connection or socket in its
  demultiplexing entry, and an interface two counters in its interface
  record, one for its driver's batches and one for what senders hand it.
* A sender adds the units it is about to send (frames, segments or
  bytes, as the receiver chose) with `atomics:add_get/3`. If the result
  exceeds the receiver's limit, it subtracts them again and does not send.
* The receiver subtracts the units of each message it takes. A receiver
  that takes several queued messages into one step subtracts their units
  once the step is done, so the counter bounds what waits and what it
  steps together, and the batch never exceeds the limit
  ([One step per mailbox](design-network-fastpath.md#one-step-per-mailbox)).
* A sender that reserved units it does not send, for a frame it then
  drops or a hand-over it abandons, subtracts them again.

Every queue between driver, interface and socket is therefore bounded by
construction, and a full queue drops at the sender, which counts the drop
by reason. Only a sender killed between its reservation and its send
leaves units it never sent: an interface process on a socket's counter, a
connection on the driver's. Each such death strands at most one
hand-over, a counter is made anew when its receiver restarts, and nothing
in the network domain kills a connection or an interface process except a
fault or a test ([Residuals](#residuals)).

For TCP the transmit credit is an input of the step: when the
driver's credit runs out mid-output, the step does what `tcp_output` does
on `ENOBUFS` (`tcp_output.c:1690-1693`): it sets the congestion window to
one segment and leaves the retransmission timer to recover.

The same rule bounds what a remote peer can queue at a connection: a
connection that falls behind fills its credit, and the interface drops
further segments for it, which the peer's congestion control sees as
loss.

The rule crosses the lane unchanged, except that an `atomics` counter
cannot be shared between domains: a socket pushes to its socket process
only within the credit that process granted it by message, counted in
bytes for a connection and for a datagram socket alike
([The socket process](#the-socket-process)). So what a socket's owner
does not read waits in the socket, inside its receive buffer or queue,
and never in a mailbox.

### Packets become checked records once; sequence numbers are integers

A frame is decoded exactly once, in the interface process, by a chain of
total decoders, one per layer, each returning `{ok, Record, Rest}` or
`{error, Reason}` and never raising. Each decoder checks its lengths
against the layer that contains it, so no protocol code ever sees an
unchecked length or a raw header. Fields are integers and binaries;
protocol numbers are compared with macros, and the only atoms a decoder
returns are its own error reasons, a closed set.

A decoder whose layer carries a checksum checks the checksum first and
then decodes; there is no decoder that skips it. The Ethernet, ARP and
IPv6 decoders have no checksum to check. The IPv4 decoder checks the
header checksum, whose cost does not grow with the frame, before it
reads any other field but the version and header length. FreeBSD's
`ip_input` reads the source and destination first, for its RFC 1122
check that no loopback address arrives on the wire
(`ip_input.c:516-524`), and checks the header checksum next
(`:526-544`), so a frame with a loopback address and a bad header
checksum is counted as a bad address there and as a bad checksum here: a
departure in a counter, with nothing on the wire changed. The TCP, UDP
and ICMPv6 decoders take the pseudo-header's partial sum and check the
sum over the whole segment, datagram or message; the ICMPv4 decoder
checks the sum over the message alone, as RFC 792 defines it and
`icmp_input` computes it (`ip_icmp.c:500`), since only ICMPv6 has a
pseudo-header (RFC 4443, section 2.3; `icmp6_input`, `icmp6.c:505`).
Each checks a sum whose cost grows with the message's length. These four
decoders, and ARP's, so that every frame takes one
path, run later than the Ethernet and IP decoders, after the frame has
reserved room at its destination ([Receiving](#receiving)): the layer
above IP is still decoded once, but not until something has room for
it. Until then the frame is a `pending()` value of `erx_net_input`: the
decoded link record, the decoded IP record when the frame has one (an
ARP frame has none), the bytes of the layer above, and the fields that
choose its destination. A
segment, datagram or ICMP record exists only as the result of its
checksumming decoder, so no step can be handed one whose checksum was
not checked; the one exception is an IPv4 UDP datagram that carries no
checksum, which RFC 768 allows. The UDP decoder takes the IP version
and applies the rules that differ by it: over IPv4 the bytes past the
UDP length are cut off and a zero checksum field means none, as in
`udp_input`; over IPv6 the UDP length must equal the payload length and
the checksum field must be nonzero, as in `udp6_input`. The encoders
take the pseudo-header's partial sum with its length field zero and add
the length themselves, since only an encoder knows its segment's length
before it encodes; the length is one 16-bit word of either pseudo-header.

Inside a connection, sequence numbers, acknowledgement numbers, SACK
block edges and timestamps are **unwrapped**: unbounded integers that
count from the initial sequence number without ever wrapping. A
connection would have to move 2^59 bytes before its values left
ERTS's small integers. The conversion lives in `erx_tcp_seq`, which has
two functions:

* `lift(Wire32, Reference)` returns the integer congruent to `Wire32`
  modulo 2^32 that lies nearest `Reference`. A received segment is lifted
  as the first stage of its step: its sequence number against `rcv_nxt`,
  its acknowledgement and SACK blocks against `snd_una`, its timestamp
  value against the last one recorded.
* `wire(Integer)` returns the low 32 bits for encoding.

The lifted segment is a different record from the decoded one, so the
step cannot confuse a wire number with a lifted one. After lifting, the
protocol code uses ordinary comparisons. FreeBSD's `SEQ_LT` family of
macros (`tcp_seq.h`) and the flags that guard against their wrap become
unnecessary: for example `TF2_NO_ISS_CHECK`, which FreeBSD sets once
`snd_una` is far enough past the initial sequence number that a modular
comparison with it means nothing (`tcp_input.c:2416-2441`), stops being
a stored flag. Since `snd_una` never decreases, the condition FreeBSD
latches is a comparison of the state, and the acceptable
acknowledgement's lower bound is FreeBSD's, without a wrap guard:
`snd_una - max_sndwnd` once `snd_una >= iss + (65535 bsl snd_scale)`,
and `max(iss + 1, snd_una - max_sndwnd)` before. So an acknowledgement
of exactly `iss`, possible only once `snd_una - max_sndwnd` has reached
it, is an old acknowledgement here as in FreeBSD, not a challenged one.

Modular comparison is not an order: at a distance of 2^31 two numbers are
each "greater" than the other. Lifting makes the order total, so a
segment whose numbers lie about 2^31 from the connection's can take a
different branch than in FreeBSD. Both outcomes refuse the segment; the
packet scripts and the explorer pin which acknowledgement, if any, the
stack sends ([Verification](#verification)).

### What disappears

| FreeBSD mechanism | Why the stack has none |
| --- | --- |
| `INP_WLOCK`, `INP_RLOCK`, the pcb-info and hash locks, lock-order rules | one owner per control block; shared tables are written by their owners only |
| `NET_EPOCH`, `in_pcbref`/`in_pcbrele`, "returns NULL if the pcb was freed" conventions of `tcp_close` and `tcp_drop` | a connection ends by exiting; a dead pid names nothing |
| callout stop and drain races, `tcp_timer_stop`'s deferred free | deadlines in state; a timer message is a hint |
| mbuf chains, `m_pullup`, `M_PREPEND`, socket-buffer compression | binaries, sub-binaries and lists of them |
| `SEQ_LT` and friends, wrap-guard flags | unwrapped integers |
| `arc4random` called from inside each decision | a generator in each owner's state, drawn from like any other field |
| virtual network stacks (`VNET`) | one stack per network domain |
| sysctl registration | the `erx_net` application's environment, and per-socket options |
| syncache buckets, per-bucket locks and callouts | one bounded table per interface process, one deadline |
| the function-block registry and aliasing (`tcp_subr.c:392-740`) | a closed table of loss and congestion modules |
| BlackBox logging, DTrace probes, `tcp_pcap` | every connection is a process the inspector and tracer see |

## Processes and the packet path

### The process tree

```text
erx_net_sup  (one_for_one, intensity 0: restarts nothing)
 |- erx_net_tables          ETS tables, secrets, port-mapper names;
 |                          monitors each interface, deletes its rows
 |- erx_net_grants  (simple_one_for_one, temporary children)
 |   |- erx_net_grant        one per client domain; traps exits
 |       ~ linked, not supervised: erx_tcp_conn, erx_tcp_listen,
 |         erx_udp_sock, each acting for that grant's domain alone
 |- erx_net_interfaces  (one_for_one)
 |   |- link supervisor per interface, its id the interface's name
 |       |                   (vtnet0 ...), permanent; rest_for_one
 |       |- the driver       erx_net_driver over its transport: erx_virtio_net or erx_genet,
 |       |                   erx_net_loop for loopback, or erx_net_pipe on a host
 |       |- erx_net_if       the interface process
 |       |- erx_dhcp4        when the interface is configured for DHCP
 |- erx_epmd                the port mapper for exposed domains
 |- the runtime's children  erx_net_runtime:children/1: the node's grant
                            `local`; on erXos also the mints of `net` and of
                            `network_ctl`, the driver-control facet
```

Every child of `erx_net_sup` is permanent, and the supervisor restarts
none: the end of any of them, `erx_net_interfaces` giving up included,
ends the stack, which runs standalone and on erXos alike. On erXos the
application is permanent in the network domain, so the stack's end ends
the domain, and the domain service restarts it, which grants the device
and every client again. A restart at the top would do less well whatever
it restarted. Minted grants are temporary and are not made again, so a
restart of the grants' supervisor, or of the tables they subscribed to
in `init`, would leave clients without the network. And a restarted mint
names itself after the domain's ready report, which no report carries,
so the domain would mint nothing more. Ending the stack instead leaves
no list of which restart destroys which grant to keep right.

`erx_net_tables` owns the shared ETS tables, so a crash of any other
process loses no table. Ordinary failures stay below the top. A driver
restart resets its device
([design-runtime.md](design-runtime.md#the-device-nif)) and restarts its
interface process, which loses only soft state: neighbour entries,
reassembly queues and half-open handshakes, which peers retransmit. The
rows a stopped interface published go with it
([What owners publish](#what-owners-publish)). A driver ends when its
medium does, and is its link supervisor's significant child, so the
whole link ends with it and the interfaces supervisor starts it again;
a driver lives a second at the least, which bounds how fast a dead
medium restarts its link, and the interfaces supervisor's intensity is
set to the most its links reach at that rate
([Ending](#the-driver)).

A link is also what the network domain's driver-control facet,
`network_ctl`, stops, starts and restarts for the system domain
([design-system.md](design-system.md#the-holders-driver-control-facet)).
Its units map the manifest's unit `net` to `{erx_net_interfaces,
Name}`, the link of the stack's one interface, which its transport
names after the domain's network device as FreeBSD names a driver's
units: `vtnet0` of `erx_virtio_net`, `genet0` of `erx_genet`.
The runtime reads the name from the interfaces `children/1` is given,
so no second list of names exists to fall out of step. One link stands
for the unit only while the unit holds one network device; with none
or several, `net` names no link and every request is refused. The
link is a permanent child with a stable id, so a stop leaves its place and a start builds the driver, the
interface and the DHCP client again in order; neither touches a grant
or the domain. The driver is not the controlled object: it is a
temporary child of the link, which a stop would remove for good.

Connections, listeners and datagram sockets are never restarted, since a
restarted TCP connection would be a different connection: each is a
`proc_lib` process running the `gen_server` loop, linked to its grant,
so the grant's end ends it and its crash is reported to the grant. The
grant traps exits, so a socket's crash ends only that socket.

### What owners publish

Every table one process writes and another reads is an ETS table of
`erx_net_tables`, so a writer's crash loses no table, and every row has
one writer, the owner of the state it shows:

| Table | Row | Writer | Readers |
| --- | --- | --- | --- |
| `erx_net_ifs` | one per interface: its name; its pid, which every other row it writes names; its two credits, one for its driver's receive batches and one for what senders hand it; its driver's pid and credit; its link (`ethernet`, or `none` for loopback); its link-layer address; its MTU, the driver's fields and these three taken from the driver's answer to the interface's attach ([The driver](#the-driver)); its IPv6 link MTU; and its IPv6 hop limit | the interface | every sender; every interface's view |
| `erx_net_addrs` | an address, `erx_net_addr:row()`, with its interface's pid and the place the interface added it in | the interface that owns it | every interface's view; every sender's source choice; the grant's `addresses` check |
| `erx_net_routes` | a route, `erx_net_route:row()`, with its interface's pid | the interface it leaves through | every sender |
| `erx_net_neigh` | a neighbour the transmit path may address, keyed by the interface's pid and the IP address: its link-layer address, `fresh` or `stale`, and a hint count | the interface, from `erx_lltable`'s `publish` and `unpublish` actions | connections and datagram sockets |
| `erx_net_gen` | one counter, the configuration generation | every writer of the first three tables; `erx_net_tables` | every reader of the first three tables |
| `erx_net_demux` | a demultiplexing entry ([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)) | `erx_net_bind`, for the socket that holds it | interfaces, through `classify/2` |
| the secrets | the ISN, timestamp and cookie keys | `erx_net_tables` | interfaces; `erx_net_bind` |

The first three are the stack's configuration, and the configuration
generation changes with them: a writer increments it after each change
of its rows. A reader reads the generation first and the rows after it,
and keeps what it builds from them, an interface's view, a sender's path
or the grant's list of local addresses, with that generation; it reads
the rows again when the generation differs. A reader that raced a writer
may build from rows newer than its generation, and then finds a newer
generation at its next read, so every copy follows a change within one
read, and nobody locks. The generation and a neighbour row's hint count
are the only fields with several writers; like a credit counter, each
carries a count and nothing else. Every reader of the configuration
reads it through `erx_net_tables:configuration/0`, which reads the
generation and then the three tables and returns the generation with
`erx_net_frame:snapshot/3` of the rows.

The generation moves only when something a path, a view or a source
choice is built from moves. An address row carries the address's flags,
`deprecated` among them, and no lifetimes: the interface keeps the
preferred and valid deadlines in its own state, sets `deprecated` when
the preferred deadline passes, as `nd6_timer` sets
`IN6_IFF_DEPRECATED` (`nd6.c:984-987`), clears it when an advertisement
makes the address preferred again (`nd6.c:1041`), and deletes the row
when the valid deadline passes. A router advertisement or a DHCP
renewal that only moves deadlines later therefore changes no row, and
an on-link sender repeating advertisements makes no reader rebuild
anything. Source selection reads the flag where `in6_selectsrc` tests
`IFA6_IS_DEPRECATED` against the clock (`in6_src.c:358-361`); the two
differ only by the time the interface takes to act on its own deadline.

**Rows end with their writer.** Every row an interface writes names its
pid, the incarnation that wrote it. An interface process registers with
`erx_net_tables` when it starts, and `erx_net_tables` monitors it, as it
monitors every grant for its sockets' entries
([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table));
when the interface stops, however it stops, `erx_net_tables` deletes
every row of the four interface tables that names that pid and
increments the generation. No path built after the generation moves
uses a row of a stopped incarnation, even before that deletion:
`snapshot/3` keeps an address or route row only when its pid is the one
its interface's `erx_net_ifs` row holds, and a transmitter looks a
neighbour up under the pid of the interface its path holds, so a path
built for a new incarnation finds only what the new incarnation
published. The generation moves when the new incarnation writes its
`erx_net_ifs` row or when the deletion runs, whichever comes first; a
path built before that sends as the old incarnation would have, and its
hand-overs to the old pid are lost as a dropped frame is, until its next
pass. A restarted interface therefore starts with no neighbour published
and resolves each next hop again, so no link-layer address the old
incarnation learnt is used beyond one pass of each sender, and a DHCP
lease that ended with its `erx_dhcp4` leaves no address or route behind.
The pid in each row is what lets the deletion match the old incarnation
alone, since the new one may publish before the old one's monitor
message arrives; the monitor is what ends the rows of an interface that
never comes back, removed by configuration or given up on by its
supervisor.

Nothing else is published. The syncache and its cookies-only state, the
neighbour tables themselves with their held packets, the reassembly
queues and the rate limiters are the interface's own state, which only
its own step reads.

### Receiving

A TCP segment for an established connection whose owner is in client
domain D:

1. **Device to driver.** The device writes a frame into a pool buffer. The
   driver's interrupt message makes it call `erx_device:complete/3`, which
   copies up to 64 KiB of completed frames into fresh binaries: the one
   per-byte copy of the receive path, which also returns each frame's
   network sum ([Checksums in the copy](#checksums-in-the-copy)). The
   driver strips the device's own
   header (virtio's `virtio_net_hdr`) and sends the batch to the interface
   process in one message, against the interface's receive credit
   ([The driver](#the-driver)). The driver
   parses nothing else, as sDDF's split of driver and protocol prescribes
   ([design.md](design.md#drivers-and-dma)).
2. **Interface: merge, classify, reserve, complete.** The interface
   first merges the batch: one call of `erx_bytes:tcp_merge/1` groups
   consecutive in-order segments of one flow, by the rule of FreeBSD's
   large receive offload, into one merged segment that stands where its
   first frame stood and counts the segments it holds
   ([design-network-fastpath.md](design-network-fastpath.md#the-merge)).
   A merged segment passes every step below as one frame, its first and
   last frames verified, and takes one unit of its connection's credit
   for each segment it holds. For each frame the interface process runs
   two pure functions of `erx_net_input` around one effect:
   ```erlang
   classify(Input, View) -> {owned, [{Pid, Credit}, ...], pending()}
                          | {local, pending()}
                          | {drop, Reason}.
   verify(pending()) -> {ok, Item} | {drop, Reason}.
   ```
   `classify/2` decodes the Ethernet and IP layers, reads the fields that
   choose a destination (the addresses, the protocol, the ports, and an
   ICMP message's type and the addresses and ports it quotes) and looks
   them up in the interface's view and the demultiplexing table
   ([Classifying a frame](#classifying-a-frame)). Its result is `owned`
   for a segment, datagram or ICMP report that belongs to sockets,
   `local` for what the interface itself handles, and `drop`. An owned
   frame then takes one unit of each destination's credit, and a local
   frame one token of the interface's ingress bucket
   ([Untrusted input](#untrusted-input)); a frame that finds neither is
   dropped and counted. Only a frame that holds its unit or token reaches
   `verify/1`, which runs the decoder of the layer above IP, or ARP's:
   for TCP, UDP, ICMP and ICMPv6 the checksum first, then the header and
   options. The checksum comes from the frame's network sum, which
   reads only headers and padding: the transport's copy gave it, or the
   merge computed it for a frame that came without one. Only a
   reassembled datagram and a loopback packet are summed here, with
   `erx_bytes:inet_csum/2`, a read pass with no copy
   ([Checksums in the copy](#checksums-in-the-copy)). A frame that fails
   gives its unit or token back and is dropped. So a frame dropped for
   want of room costs a header decode and one lookup, whoever it names,
   on every transport whose copy sums. On the pipe, whose frames come
   without a sum, the merge sums every frame before it is classified, so
   there each frame costs the read of its bytes whether or not anything
   has room for it ([Residuals](#residuals)). A frame that holds room
   and then fails its checksum costs the checksum as well, and because
   it gives its unit or token back, neither credit nor the ingress
   bucket bounds that work: frames with bad checksums are checksummed at
   the rate the link delivers them, as FreeBSD checksums every frame it receives.
   The fields `classify/2` reads are the only ones read before their
   checksum is checked, and they are used for the lookup alone: a local
   frame is answered only from its verified item, so a segment with a
   bad checksum to a closed port draws no RST, as in FreeBSD. A
   reassembled IP datagram passes `classify/2`, the reservation and
   `verify/1` as a frame does.

   FreeBSD checks every checksum before its lookup (`tcp_input.c:744-748`
   before `in_pcblookup_mbuf` at `:881`; `udp_input`'s check at
   `udp_usrreq.c:554-586` before its lookup at `:624`). Checking after
   the reservation is a departure in order only: a frame with a bad
   checksum is dropped either way and nothing on the wire differs, but a
   corrupted frame that also found no room is counted as dropped for want
   of room, where FreeBSD counts it as a bad checksum. The order is
   chosen so that one interface process, the classifier for every
   client, spends a constant cost on each frame it drops for want of
   room ([Residuals](#residuals)).
3. **Interface to connection.** The owned items of one batch are grouped
   by destination, and each destination gets one message holding its
   items in arrival order and naming the interface, against its credit.
   The items are records whose payloads are sub-binaries of the frames,
   a merged segment's the list of its frames' payloads, so nothing is
   copied.
4. **Connection.** The connection takes every items message waiting in
   its mailbox and folds `erx_tcp:step/3` over their segments, one at a
   time, a merged segment as one, exactly as FreeBSD processes one
   segment, or one LRO packet, at a time, collecting the actions
   ([design-network-fastpath.md](design-network-fastpath.md#one-step-per-mailbox)).
   It then sends all frames and runs the steps produced (ACKs, data) to
   the driver in one message, pushes the in-order data its socket
   process has credit for to that process, in pushes of at most one
   piece of 64 KiB each ([Message sizes](#message-sizes)), replies to
   its requests and re-arms its timer.
5. **Connection to socket process.** The push is
   `{erx_net, Conn, {data, Pieces}}`, `Pieces` the receive queue's
   binaries as they are, a frame on the lane from the network domain to
   the owner's domain D, decoded by D's funnel and delivered as
   `{erx_origin, Net, {erx_net, Conn, {data, Pieces}}}`.
6. **Socket process to owner.** The socket process checks the push and
   presents it as its options say: in active raw mode as one
   `{tcp, Socket, Data}`, its pieces joined into one binary, a local
   message in D ([The socket process](#the-socket-process)).

### Classifying a frame

`erx_net_input` is the receive decision of FreeBSD's `ether_demux`,
`ip_input`, `ip6_input` and the pcb lookups of `tcp_input_with_port`,
`udp_input` and the protocols' ICMP handlers, taken as far as choosing
where a frame goes and no further. Its input is a frame from the driver,
`{frame, Bytes, Sum}`, with `Sum` its network sum or `none`
([Checksums in the copy](#checksums-in-the-copy)); on the loopback interface, an IP packet with the zone
its sender's path gave it, `{frame, Zone, Bytes}` ([Loopback](#loopback));
or a datagram reassembly rebuilt, `{reassembled, Family, Zone, LinkCast,
Bytes}`. The last two carry no sum. Its view is a map:

```erlang
-type view() :: #{link := ethernet | none,      % none: the loopback interface
                  lladdr := <<_:48>> | none,
                  ip4 := erx_ip4:view(),
                  ip6 := erx_ip6:view(),
                  groups := [<<_:128>>],         % IPv6 groups the interface joined
                  dhcp := boolean(),             % configured for DHCP
                  demux := fun((key()) -> [entry()])}.
```

Everything but `demux` is built by the interface core from its own state
and its copy of the configuration ([What owners publish](#what-owners-publish)),
and rebuilt when the configuration generation changes: `ip4` and `ip6`
list every address of the stack, with its zone, as the weak end-system
model accepts any of them on any interface; and `groups` are the
all-nodes group and the solicited-node group of each of the interface's
IPv6 addresses, tentative ones included, which it joins before duplicate
address detection. `demux` is the lookup the loop passes: `ets:lookup/2`
on the demultiplexing table in the interface, a map in the tests and the
fuzz target. It is the only shared state `classify/2` reads, so its
result is a function of the frame, the view and what the lookup answers.

**Zones.** Inside the stack an IPv6 address of link-local or
interface-local scope, unicast or multicast, never travels without its
zone: it is the pair of the address and the interface it belongs to, as
FreeBSD embeds the zone in the address itself (`in6_setscope`,
`sa6_embedscope`, `scope6.c:322-352`), and every other address is its
bytes alone (`erx_net_addr:zone/2`). A received packet's addresses take
the zone of the interface it arrived on; a looped packet's take the zone
its sender's path gave it, which the loopback interface carries in front
of the packet as `nd6_output_ifp` hands the loopback interface the
original one (`nd6.c:2226-2229`); the addresses an ICMPv6 error quotes
take the zone of the packet that carries them. The view's address
lists, the demultiplexing keys and a path's destination all hold zoned
addresses, so "is this address ours" and "whose key is this" compare
the zone with the address. Two sockets bound to `fe80::1` on port 80 of
two interfaces hold two keys; a segment from a link-local peer on one
interface never matches a connection made on another; and an ICMPv6
error the stack sends itself, to one of its own link-local addresses,
arrives through the loopback interface in that address's zone and finds
the socket its quote names. A scoped address given without its zone is
no address of the stack, as FreeBSD's lookup finds none for it.

A fragment keeps its zone through reassembly. Its item carries the zone
its packet's addresses took and its frame's link cast,
`{fragment, Family, Zone, LinkCast, Ip, Bytes}`, and `erx_ip6_reass`
keys a datagram by its zoned source and destination and its
identification, so fragments that arrived in two zones never join, as
FreeBSD's embedded zone keeps them apart in `frag6_input`'s hash. The
rebuilt datagram takes the zone and the link cast of its fragment at
offset 0, as `ip_reass` and `frag6_input` keep that fragment's packet
header, and the interface classifies it as `{reassembled, Family, Zone,
LinkCast, Bytes}`; IPv4's zone is always `none`. A datagram whose
lifetime ends returns its first fragment with that fragment's zone, and
only a first fragment that came as a link-layer unicast, since
`icmp6_error` answers none of the others (`icmp6.c:309`); and
a parameter problem carries its packet's zone,
`{param_problem, Family, Zone, Problem, Packet}`, so the ICMPv6 error
either sends goes back to the zoned source.

Classification runs in three steps:

1. **Link.** On Ethernet, a frame to the interface's address is
   `unicast`, one to the broadcast address `broadcast`, one with the group
   bit `multicast`, and any other is dropped as `other_host`, as
   `ether_input` drops it without promiscuous mode; an EtherType other
   than IPv4, IPv6 and ARP is dropped as `ethertype`. On loopback the
   frame is the IP packet with its zone, `unicast`, its family read from
   the version.
2. **IP.** On an interface configured for DHCP, an IPv4 packet whose
   header `erx_ip4_wire:decode/1` accepts, that is not a fragment, and
   that carries UDP with at least a UDP header's 8 bytes to port 68 is
   `local`, for the DHCP path, before any address check. This is the
   test of `dhclient`'s receive filter, which sees every frame ahead of
   `ip_input` (`dhcp_bpf_filter`, `bpf.c:188-251`). That filter tests
   only the fragment offset, so it also passes a first fragment; erXos
   takes only a whole packet, since a DHCP message fits in one frame, and
   a fragmented one is reassembled and classified like any other
   datagram, without the DHCP path. A unicast offer to
   the address being offered passes it although that address is not yet
   the stack's. Every other packet goes to `erx_ip4:input/3` or
   `erx_ip6:input/4`, with the view's `ip4` or `ip6` and, for IPv6, the
   zone it arrived in. Their drop is the verdict; a fragment and a
   parameter problem are `local`. A datagram to an IPv6 group the
   interface has not joined, or to any IPv4 group, is dropped as
   `not_member`: the core joins no IPv4 group, and `erx_mcast` adds
   sockets' memberships to the view.
3. **Above IP.** Only the fields the table names are read:

| Datagram | Fields read | Verdict |
| --- | --- | --- |
| TCP | ports | the connection's key: `owned`. Else a listener's key: `local` when both the frame's link cast and its destination's class are `unicast`, else dropped as `bcast_tcp`, as `tcp_input` drops a link-layer broadcast or multicast for a listener (`tcp_input.c:1288`) and a SYN to a broadcast or multicast address before `syncache_add` (`tcp_input.c:1326-1338`), and `tcp_dropwithreset` answers neither when SYN is clear (`:3450-3471`), with one departure: an ACK or RST of a handshake in a link-layer broadcast or multicast frame is dropped too, where FreeBSD's `syncache_expand` and `syncache_chkrst` see it first (`:1081`, `:1175`); the checks there that read the four-tuple alone, a connection to or from itself, a multicast source and the limited broadcast as source (`tcp_input.c:1295-1338`), are the syncache's, on the verified item. Else `local` if it may be answered (a RST), else dropped as `no_reply` |
| UDP | ports | the holders of its keys, most specific first, reduced by `erx_udp:input/3`: `deliver` is `owned` by those sockets, `port_unreach` is `local`, `{drop, no_port}` the verdict |
| ICMP or ICMPv6 error | type; the quoted protocol, addresses and ports | the quoted datagram, which the stack sent, read by `decode_quoted/1` with its source as the local end: a TCP connection's key or a connected UDP socket's key is `owned`; a TCP listener's key is `local`, for `syncache_unreach`; else dropped as `no_socket`, and a quote `decode_quoted/1` refuses is dropped with its reason |
| ICMP echo or timestamp request, ICMPv6 echo request | type | `local` if it may be answered, else dropped as `no_reply` |
| ICMP redirect; ICMPv6 router and neighbour messages, redirect, MLD query | type | `local` |
| ICMP echo reply | type; the identifier | the key of the echo socket that holds the identifier: `owned`; else dropped as `no_socket`, and a reply shorter than the echo header as `too_short`. Its checksum and length are checked by `verify/1` (`erx_icmp4_wire:decode/1`), so the socket receives only whole replies |
| any other ICMP or ICMPv6 type | type | dropped as `icmp_type` |
| ARP | none | `local` |
| any other protocol | protocol | `local` if it may be answered, for the protocol unreachable `rip_input` sends (`raw_ip.c:410`) or the parameter problem at the next-header byte `rip6_input` sends (`raw_ip6.c:321-324`); else dropped as `no_reply`. IPv6's No Next Header is dropped as `no_next_header`, as `rip6_input` frees it unanswered |

A datagram too short to hold the fields its row reads (the ports, or an
ICMP type) is dropped as `too_short` before verification, where
FreeBSD's decoder drops it in the same place under its own counter.

The keys of a datagram from `RemoteAddr:RemotePort` to
`LocalAddr:LocalPort` are, most specific first,
`{tcp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`,
`{tcp_listen, Family, LocalAddr, LocalPort}` and
`{tcp_listen, Family, any, LocalPort}`, and for UDP the same three with
`udp`. An ICMP error's quote finds an owner by the first key alone, as
`tcp_ctlinput` and `udp_common_ctlinput` look up only the full
four-tuple; a TCP quote without one goes to the syncache, as
`tcp_ctlinput` hands it to `syncache_unreach` (`tcp_subr.c:3128-3176`),
but only when a listener's key exists, since only a listener's
handshakes are in the syncache. `pending()` holds what `verify/1` and the item's consumer
need: the link and IP records, the cast and whether the datagram may be
answered, the bytes above IP with their pseudo-header's partial sum, and
the listener's entry for a segment to a listener.

**Room.** An owned frame takes one unit of each destination's credit; a
destination without room is skipped and counted, and a frame no
destination took is dropped as `no_room`. Which local frames spend a
token is `erx_net_if_core:charge/2`'s decision, since only the core
holds the neighbour tables: an ARP reply or a neighbour advertisement
whose target the core is resolving is free, and every other local frame
spends one, or is dropped as `no_token`.

**Verification.** `verify/1` is a function of `pending()` alone: the
TCP, UDP and ICMPv6 decoders with the pseudo-header's sum, the ICMP and
ARP decoders over their bytes. A fragment, a parameter problem and a
datagram of another protocol have nothing more to check and pass as
they are. Its item is the record its consumer's step takes: for a
connection `erx_tcp:segment()`, the decoded header, its payload, the
ECN field of its IP header and its frame's link cast; for a datagram
socket `{datagram, {SrcAddr, SrcPort}, DstAddr, Payload}`; for a socket
an ICMP report, the decoded
message with its quote; and for the interface the same records with the
IP record and whether the datagram may be answered, which the core hands
to `erx_arp`, `erx_nd6`, `erx_icmp4`, `erx_icmp6`, `erx_tcp_syncache`,
`erx_udp`, its DHCP path or its reassembly. A frame owned by several
sockets is verified once and its item delivered to each.

**Order within a batch.** The interface classifies, reserves for and
verifies its frames one at a time, and runs the core on a local frame
before it classifies the next, so a key the core inserts, a connection
the syncache completed, and a datagram reassembly completed are seen
from the next frame on; owned items are sent at the end of the batch,
grouped by destination.

**Reinjected segments.** A connection returns with `reinject` every
segment of its batch after the one that ended it, and in TIME-WAIT the
SYN that RFC 6191 lets end it ([TIME-WAIT](#time-wait)), since each is
for a connection that no longer exists. Its loop sends them back to the
interface process that delivered the batch, which its batch message
names, as `{reinject, Key, [segment()]}` with the connection's own key,
against that interface's sender credit. The key gives what the segment
lacks: the family, the addresses, zoned, and the ports; the segment
carries its header, payload, ECN field and link cast. The interface
treats each as a local frame that has passed `verify/1`: it spends a
token of the ingress bucket, is looked up by the listener keys alone,
since the full key still finds the ended connection until its grant
deletes the entry, and without a listener is answered as a segment to a
closed port, so it may draw a RST under the RST limit, as `tcp_input`
looks each segment up anew and finds the listener or nothing.

### Transmitting

1. **Owner to connection.** `gen_tcp:send/2` in D calls the socket
   process, a local call, which sends the data to the connection in
   pieces of at most 64 KiB, one at a time, each
   `{erx_net, SockProc, {call, N, {send, Piece}}}`
   ([Message sizes](#message-sizes)): a frame on the lane, decoded by the
   network domain's funnel into a binary of the network domain.
2. **Connection.** The step appends the binary to the send buffer, a
   queue of binaries, and runs output. Output emits runs, segments that
   share one header: a run's payload is sub-binaries of the buffer, and
   its header is the connection's template with the values output chose
   and the next hop's link header from its neighbour row
   ([design-network-fastpath.md](design-network-fastpath.md#sending)). A
   segment no run can carry, a SYN or a segment with SACK blocks among
   them, is encoded with `erx_net_frame` over its path and the neighbour
   row ([Framing](#framing)). When the interface's driver finishes
   checksums, that segment's checksum is left delayed for the copy in
   step 4; otherwise it is computed over the headers and payload with
   `erx_bytes:inet_csum/2` ([Checksums in the copy](#checksums-in-the-copy)).
3. **Connection to driver.** All runs and frames of the step go to the
   driver in one message against the driver's credit, one unit for each
   frame a run holds, each frame as its header binary and its payload
   sub-binaries.
4. **Driver to device.** The driver posts each run and frame with
   `erx_device:post_frame/5`, which walks a frame's binaries itself and
   cuts a run into frames as it lays each in a pool buffer behind the
   device's header, finishing its checksums and a delayed frame's: the
   one per-byte copy of the transmit path
   ([design-network-fastpath.md](design-network-fastpath.md#each-transports-cut)).

### Framing

Every owner that sends IP, a connection, a datagram socket or an
interface, frames through `erx_net_frame`, which translates the
header-building and next-hop parts of `in_pcbladdr`, `ip_output`,
`ip6_output`, `ether_output` and `arpresolve_addr`. It is pure; what it
needs from the published tables reaches it as two values the caller
reads: a path, built from the configuration, and the next hop's
neighbour row.

```erlang
snapshot(Ifs, Addrs, Routes) -> snapshot().
path(Dst, Opts, snapshot()) -> {ok, path()} | {error, enetunreach | eaddrnotavail | eacces}.
    % Dst zoned; Opts: src, via (an interface), ttl or hlim, tos or tclass, flow, broadcast
tcp(path(), [erx_tcp:outgoing()], gen()) -> {ok, [packet()], gen()} | {error, emsgsize}.
udp(path(), Sport, Dport, iodata(), gen()) -> {ok, [packet()], gen()} | {error, emsgsize}.
ip(path(), Proto, iodata(), gen()) -> {ok, [packet()], gen()} | {error, emsgsize}.
address(path(), none | {LinkAddr, fresh | stale}, [packet()]) ->
    {send, [frame()]} | {resolve, [packet()]}.
link(Iface, LinkAddr, [packet()]) -> [frame()].
```

**The path** is everything about the way to one destination that does
not change from packet to packet, with the configuration generation it
was built at:

* *Interface.* The first of these that applies:
  * A destination that is an address of the stack, compared with its
    zone, leaves through the loopback interface in that zone, as the
    loopback route FreeBSD adds for each address sends it
    (`ifa_maintain_loopback_route`).
  * A multicast destination, or the limited broadcast
    `255.255.255.255`, sent through a named interface (the `via`
    option) leaves through that interface without a route. FreeBSD
    bypasses the route lookup for a multicast with an interface given
    (`ip_output.c:456-470`; `in6_selectif`, `in6_src.c:741-744`), and
    `dhclient` writes its broadcasts through BPF, under IP. A link- or
    interface-local multicast names its interface by its zone, as
    `in6_selectif` takes it from the zone (`in6_src.c:746-755`).
  * Any other destination takes `erx_net_route:lookup/2`, or `lookup/3`
    on its zone's interface for a zoned one, and no route is
    `enetunreach`, as `in_pcbladdr` refuses (`in_pcb.c:1270`).

  `via` comes from the interface for its own packets, and from a
  socket's multicast interface option (`IP_MULTICAST_IF`,
  `IPV6_MULTICAST_IF`), which applies only to a multicast destination;
  so only the interface sends a limited broadcast without a route, and a
  socket's broadcast takes a route as `ip_output`'s does. The
  interface's DHCP broadcasts, router solicitations, duplicate address
  detection and neighbour solicitations to solicited-node groups,
  advertisements to all-nodes and MLD reports therefore have paths
  before the interface has an address or a route.
* *Next hop and its link address.* The route's gateway, or the
  destination when the route has none or the path took no route. On
  loopback the link header is the zone; a broadcast destination takes
  the broadcast address, and a multicast one its mapped address
  (`ETHER_MAP_IP_MULTICAST`, `if_ether.c:620`, and its IPv6 twin), as
  `arpresolve_addr` gives them; any other unicast next hop is addressed
  by its neighbour row.
* *Source.* The one given, or the one chosen: `erx_in6_src:select/3`
  for IPv6, over the address rows and their `deprecated` flags, and for
  IPv4 the outgoing interface's address whose prefix holds the next hop,
  else the first the interface added, as `in_pcbladdr` takes the route's
  interface address and `if_addrhead` lists addresses in the order they
  were added; no usable address is `eaddrnotavail`. A socket's given
  source is the one `erx_net_bind` checked when it bound, never the
  unspecified address; only the interface gives `0.0.0.0` or `::`, for
  DHCP before it holds a lease, and for duplicate address detection and
  router solicitations before it holds a usable address, as RFC 4862
  and RFC 4861 send them.
* *Header fields.* The driver's and interface's pids and credits from
  the interface's row, and the MTU: for IPv4 the row's MTU, for IPv6 its
  IPv6 link MTU, which is a router advertisement's MTU when that is
  below the interface's and the interface's otherwise (`IN6_LINKMTU`,
  `nd6.h:103-107`). The hop limit, type of service or traffic class and
  flow label come from the caller's options. The hop limit defaults to
  1 for a multicast destination, as `IP_DEFAULT_MULTICAST_TTL` and
  `ip6_defmcasthlim` give it (`in.h:535`, `in6.h:521`); otherwise to the
  interface's for IPv6, which router advertisements set, and to 64 for
  IPv4 (`IPDEFTTL`). Neighbour discovery's messages set 255, as RFC 4861
  requires.
* *Broadcast.* A destination that is an IPv4 broadcast address of the
  outgoing interface (`erx_net_addr:is_broadcast/3`, the limited
  broadcast among them) marks the path `broadcast`, as `ip_output`
  sets `isbroadcast`, and is refused as it refuses one
  (`ip_output.c:661-673`): `eaddrnotavail` on the loopback interface,
  which cannot broadcast, and `eacces` unless the caller's `broadcast`
  option allows it. A socket passes its `broadcast` option there
  (`SO_BROADCAST`, which `ip_output` reads as `IP_ALLOWBROADCAST`), a
  connection never does, and the interface does for its own
  broadcasts. `udp/5` and `ip/4` refuse a broadcast packet over the
  MTU with `emsgsize` instead of fragmenting it.

**Packets and frames.** `tcp/3`, `udp/5` and `ip/4` build IP packets,
each the iodata `[Header, Payload]` that `erx_ip4:output/4` and
`erx_ip6:output/4` return: the header bytes they build, and the payload
binaries as they were given, not copied. Only a datagram that IP
fragments has its payload joined into one binary, which those functions
then cut into fragments. `tcp/3` encodes each segment with
`erx_tcp_wire:encode/4` over the path's pseudo-header sum, its checksum
delayed for the driver to finish when the path's interface row says the
driver finishes checksums and IP will not fragment the segment, a
packet then of the form `{csum, Start, Field, Packet}`
([Checksums in the copy](#checksums-in-the-copy)), and
`erx_ip4:output/4` or `erx_ip6:output/4` with the segment's marks: its
ECN field in the low bits of the type of service or traffic class, and
don't-fragment as the segment says. A segment without don't-fragment
that is over the MTU is fragmented. A segment under don't-fragment that
is over it is refused with `emsgsize`, as `ip_output` refuses it, and
nothing raises. Output's rule of [Output](#output) makes that refusal
unreachable for segments sized against the path they are framed on,
since the context's MTU is that path's; were it reached, the pass's
frames would be dropped and counted as `emsgsize`, as lost frames
retransmission recovers. An IPv4 datagram without don't-fragment takes
its identification from the generator passed in, which is returned
advanced: a datagram socket's
own, the interface's own, and for a connection a second generator its
loop splits from its initial one, since the control block's generator is
the step's. `address/3` turns packets into frames, the link header put
in front of their headers: with the path's fixed link address, or the
row's when the next hop has one; with no row, the packets go to the
interface instead (`resolve`). `link/3` is the same framing for the
interface, over its own row, with the link address from its own table.

A multicast whose hop limit is 0 is never handed to a network: a
datagram socket hands its frames only to the loop below, never to the
driver, as `ip_output` and `ip6_output` loop such a datagram but free
the copy for the wire (`ip_output.c:632-643`, `ip6_output.c:921-935`).

A datagram a socket sends through an Ethernet interface to a broadcast
address, or to a multicast address while the socket's multicast loop
option is on, as it is by default (`IP_DEFAULT_MULTICAST_LOOP`,
`in.h:536`; `IPV6_DEFAULT_MULTICAST_LOOP`, `in6.h:522`), is also heard by
the stack itself: the sender hands the same frames to the path's
interface as `{loop, Frames}`, against its sender credit, and the
interface classifies each as a frame from its driver. This is the copy
`ether_output` loops back for every broadcast on a simplex interface
(`if_ethersubr.c:384-404`) and `ip_mloopback` and `ip6_mloopback` loop
for multicast (`ip_output.c:590-600`, `ip6_output.c:884-893`), and the
copy is received on the interface it was sent through, as theirs is;
classification then drops a copy to a group the interface has not
joined, as it drops such a frame from the wire. Only sockets' datagrams
are looped: the interface writes its DHCP broadcasts as `dhclient`
writes them, through BPF, which loops nothing, and neighbour discovery
turns the loop off for its own messages (`nd6_nbr.c:470`, `:1028`).

**A connection's output pass** reads the published state at fixed
points around its step:

1. It reads the configuration generation and, when it differs from its
   path's, reads the configuration with
   `erx_net_tables:configuration/0` and builds the path again; a path
   whose route has gone keeps that state with the generation.
2. When the path addresses its next hop by row, it reads that row, keyed
   by the path's interface pid and the next hop.
3. Its step's context holds the path's MTU, the free credit of where the
   frames will go (the driver when the next hop is addressed, the
   interface's sender credit when it has no row), and the route's
   state: `ok`, or `{error, ehostunreach}` when the path has no route, `ip_output`'s
   error for it (`ip_output.c:493`). With that error output sends nothing
   and takes `tcp_output`'s branch for it (`tcp_output.c:1709-1716`): the
   retransmission timer runs as on loss, and past SYN-RECEIVED the error
   is kept as the connection's soft error, which its timeout reports in
   place of `etimedout`.
4. It frames the step's segments with `tcp/3` and `address/3` and sends
   the frames to the driver, or hands the packets to the interface as
   `{resolve, NextHop, Src, Packets}`, each against the receiver's
   credit. The step's `reset` segments are framed the same way and
   handed to the path's interface as `{reset, NextHop, Src, Packets}`,
   and each `charge_rst` as `charge_rst`, against its sender credit: the
   interface sends a reset only within its RST limit, resolving its next
   hop as for `resolve`, and counts each charge against that limit.
5. When the row was `stale`, it increments the row's hint count with
   `ets:update_counter/3`; the one transmitter that gets 1 sends the
   interface `{hint, NextHop}`, and the interface's next `publish` of the
   row writes the count back to zero. The increment runs where a deleted
   row raises `badarg`, which means the row has gone and no hint is
   due; `update_counter/4` with a default is never used, since it would
   make a row the interface never published. A hint carries no packet
   and takes no credit: only the transmitter that moves a count from 0
   sends one, so at most one is in flight for each published row, and a
   message to a live process is not lost. A hint for an entry that is no
   longer stale, or no longer exists, is ignored. In neighbour discovery
   a hint moves a stale entry to DELAY, as `nd6_resolve_slow` does
   (`nd6.c:2424-2425`), which publishes nothing, so the count stays
   above zero, and no second hint is sent, until the entry is
   confirmed, published fresh, or deleted.

A datagram socket does the same per datagram, with a path kept per
destination of a connected socket and built for each destination of an
unconnected one. The interface frames its own packets (ICMP answers,
RSTs, SYN-ACKs, neighbour discovery) with the same functions over the
same configuration copy as its view, but resolves its next hops in its
own tables instead of reading rows.

**Resolution.** The interface hands each packet of a `resolve` to
`erx_arp:resolve/5` or `erx_nd6:resolve/6`, which send it at once when
the entry has meanwhile been resolved and otherwise hold it, at most 16
per neighbour as FreeBSD holds (`arp_maxhold`, `if_ether.c:114`;
`nd6_maxqueuelen`, `nd6.c:125`), the oldest dropped past that
(`lltable_append_entry_queue`); their `{send, LinkAddr, Packets}` action
becomes frames by `link/3`. Handing a packet to the interface counts as
sending it, as `ether_output` reports success for a packet `arpresolve`
holds (`if_ethersubr.c:350`), so TCP recovers a dropped one by
retransmission. An ARP entry that is never answered is deleted with its
packets after 20 s (`arpt_down`); a neighbour-discovery entry returns its
oldest packet as `unreachable`, and the interface sends an ICMPv6
address-unreachable error to that packet's source, an address of the
stack, so the error crosses the loopback interface in that address's
zone and `classify/2` hands it to the socket its quote names, as any
ICMP error.

**What senders hand an interface.** Everything a sender hands its
interface, `resolve`, `reset`, `charge_rst`, `loop` and `reinject`, goes
against the interface's sender credit, never its receive credit, so no
amount of sending keeps the driver's receive batches from their room.
What the interface holds for senders is bounded by its neighbour table,
1,024 entries of 16 held packets each, about 25 MB of payload at an MTU
of 1,500 bytes, shared by every client; which client's packets an entry
holds is not counted, a residual ([Residuals](#residuals)).

### Hops and copies

| Path | Local messages | Lane crossings | Copies in the network domain |
| --- | --- | --- | --- |
| receive, TCP segment | driver to interface (per batch), interface to connection (per batch); in the owner's domain, socket process to owner (per delivery) | one per push of up to a piece, and one credit message per half of the socket process's target, in every active mode | one, `erx_device:complete/3`, which also sums the frame |
| transmit, TCP segment | in the owner's domain, caller to socket process and back (per `send` call); connection to driver (per step) | one per piece of a `send`, with no reply, and one send credit message per half of the send buffer acknowledged | one, `post_frame/5`, which cuts runs and finishes checksums as it copies |
| receive, UDP datagram | driver to interface, interface to socket; in the owner's domain, socket process to owner | one per datagram, and one credit message per half of the socket process's target | one |
| ARP, neighbour discovery, ICMP echo, SYN | driver to interface; replies interface to driver | none | one each way |

A lane crossing copies the payload into the lane and out of it, by the
domains design ([design-domains.md](design-domains.md#flow-control)), and
a delivery's payload pieces become one binary once, in the socket
process, where `gen_tcp`'s API needs one. The local hop from the socket
process to the owner copies no payload over 64 bytes, since ERTS passes
a binary that size or larger by reference. The copies of each path on
each medium are counted in
[design-network-fastpath.md](design-network-fastpath.md#copies).

### Checksums in the copy

Inside the network domain each byte of a TCP segment is read once on
each path: by the copy between a device's buffer and a binary. That copy
also computes the segment's Internet checksum, so no second pass reads
the segment to sum it. The same holds on a host whose transport copies
frames in C, as the netmap transport does. Over a tap device the
kernel's `read` and `writev` are the copy, and the tap transport's NIF
sums each frame in the same call, reading its bytes once more while
they are in the cache ([The tap transport](#the-tap-transport)). The
copy that sums also cuts a run into its frames
([design-network-fastpath.md](design-network-fastpath.md#the-cut-in-the-copy)).

**The problem.** Without this, a received segment is read twice: by the
copy out of the device's buffer, and by `erx_tcp_wire:decode/2`, which
sums the segment with `erx_bytes:inet_csum/2` in the interface process.
A sent segment is read twice as well: by the TCP encoder, which
sums its header and payload in the connection process, and by the copy
into the device's buffer. The second read finds the bytes in the cache,
but it costs a call, a walk over the frame's pieces and a pass
over its bytes, in the two processes every segment passes through: the
interface process, which classifies for every client, and the
connection, which is one flow's ceiling
([todo-performance.md](todo-performance.md)). The evidence is thin, and
the measurements below settle it. In the FreeBSD run of 2026-11-09 with the
C primitive loaded, `erx_bytes` held 3.1 percent of the connection
process's samples on send
([design-network-fastpath.md](design-network-fastpath.md#where-a-segments-cost-goes)),
where the pure-Erlang stand-in it replaces had held 55 percent. The C primitive
takes about 0.30 microseconds for a 1,480-byte segment on the
development host (Apple M3 Max, macOS, stock OTP 29.1.2 with the JIT,
clang -O2, 200,000 calls). lwIP reached 6.5 Gbit/s over the same tap,
about 550,000 frames a second each way. At that rate, 0.30 microseconds
a frame would be about a sixth of one scheduler in each direction. That
estimate is not measured on the FreeBSD test host.

**The construction.** A checksum is a sum of 16-bit words, and a copy
reads every word, so the copy sums what it copies. What it hands over
is a sum, never a verdict, because the copy parses nothing:

* *Receiving*, the copy returns each frame with its **network sum**:
  the RFC 1071 one's-complement sum, folded to 16 bits and not
  complemented, of the frame's bytes from the end of its link header to
  its end. That is what `erx_bytes:inet_csum(0, Bytes)` returns for
  those bytes. The copy knows only the offset where the sum starts. Each
  layer above derives the sum of the bytes its checksum covers from the
  network sum. It subtracts the sums of the bytes it does not cover:
  headers its decoders read anyway, and the frame's padding. No payload
  byte is read again to check it.
* *Transmitting*, a TCP segment can leave its sender with a **delayed
  checksum**. Its checksum field holds the sum of the pseudo-header with
  the segment's length, not complemented, and the frame names the
  offset where the summed range starts and the field's offset within
  it. Whatever copies the frame onto the medium finishes it. As it
  copies, it sums the bytes from that start to the frame's end, field
  included, and stores the complement in the field. This is FreeBSD's
  delayed checksum: `tcp_output` sets `CSUM_TCP`, with the field's
  offset in `csum_data` and `in_pseudo` in `th_sum`. `ip_output` then
  finishes it with `in_delayed_cksum` when the interface's
  `if_hwassist` lacks the flag, and `ip_fragment` finishes it before it
  cuts. Here the device NIF's copy takes the place of the device.

The stack sees one interface whichever medium is behind it. A received
frame comes with its network sum or without one, and a sent segment is
delayed only when its interface's driver finishes checksums, which the
driver states once, when the interface attaches.

**What crosses the driver's seam.** These types extend those of
[The driver](#the-driver) and [Framing](#framing):

```erlang
%% erx_net_driver: a received frame, and who finishes a delayed checksum and a run's cut
-type rx_frame() :: binary()                      % no sum: the merge sums it
                  | {sum, 0..16#ffff, binary()}   % with its network sum
                  | {Zone :: term(), binary()}.   % the loopback interface's
-type link_info() :: #{..., finish := copy | device | none}.

%% erx_net_frame: a frame handed to a driver
-type frame() :: iodata()
               | {csum, Start :: non_neg_integer(), Field :: non_neg_integer(), iodata()}
               | {Zone :: term(), packet()}.
```

`finish` says who finishes what the sender leaves unfinished, a delayed
checksum and a run's cut, since one copy does both
([design-network-fastpath.md](design-network-fastpath.md#the-seam)):
`device` when the device does, `copy` when the transport's own copy
does, and `none` when nobody below the sender does. With `none`, the
frame layer finishes every checksum and cuts every run itself. The
interface writes `finish` into its row with the MTU, from the one
answer to its attach, so the value has one source. Who finishes is a
fixed property of the transport: `erx_virtio_net` finishes through the
device or its copy at every start, the tap and netmap transports always
through their copy, and the pipe and the loop never, but for the test
configuration of the pipe's `process` end in its offload mode. So a
driver's restart never changes whether a row's driver finishes.

| Transport | Received frames | `finish` |
| --- | --- | --- |
| `erx_virtio_net` | `{sum, S, Frame}`, from `erx_device:complete/3` | `copy`; `device` where the device offers `VIRTIO_NET_F_CSUM` with `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`, an extension ([Scope](#scope)) |
| `erx_netmap` | `{sum, S, Frame}`, from its NIF's copy | `copy` |
| `erx_tap` | `{sum, S, Frame}`, summed by its NIF after the kernel's `read` | `copy` |
| `erx_net_pipe` | `Frame`, which the interface's merge sums; a test's `process` end may give `{sum, S, Frame}` | `none`; `copy` in the `process` end's offload mode |
| `erx_net_loop` | `{Zone, Packet}` | `none` |

**The copy's core.** The C core of the checksum, `erx_inet_csum.c` in
`erx_net`'s `c_src/`, gains one function. Every copy that sums or
finishes calls it:

```c
/*
 * Copies length bytes from src to dst and returns sum continued over the bytes stored, as
 * erx_inet_sum(sum, dst, length, offset) would return after the copy. Each word of src is
 * loaded once, and the value loaded is both stored and added.
 */
uint16_t erx_inet_copy_sum(uint16_t sum, uint8_t *dst, const uint8_t *src, size_t length,
    size_t offset);
```

It loads eight bytes at a time, two words a step into two totals, and
adds them with deferred carries. Each word is loaded once and the loaded
value is the one stored, so the sum is the sum of the bytes in the
binary even when a device writes its buffer again during the copy. C
would let a compiler load a plain object a second time for a second
use, so each loaded word passes through an empty assembly statement
that hides its value from the compiler, and every use reads the
register it was loaded into. A copy followed by a pass over the source
would not give that. `erx_inet_sum` runs the same loop without the
store, and the core's oracle in its tests and fuzz target is a model
that adds one byte at a time. No test can see a second load of the
source, so review keeps every load of the loop behind the statement.
erXos's device NIF and a host
transport's NIF link the same core from `c_src/`. Those are the paths of
[Two places, four seams](#two-places-four-seams), and they run one way.

**Receiving.** `erx_device:complete(Dev, Q, SumFrom)` copies exactly as
`complete/2` does and answers `{ok, [{Tag, Bytes, Sum}]}`. `Sum` is the
sum of `Bytes` from the even offset `SumFrom` to its end, and 0 when
`Bytes` is shorter. The virtio transport passes 26: its 12-byte
`virtio_net_hdr` and the 14-byte Ethernet header. So after it strips its
header, each `{sum, S, Frame}` carries the network sum of `Frame`. The
copy is the same bounded call as `complete/2`, less than 64 KiB and one
buffer per call, with nothing added but the additions.

In the stack, a frame's input to `classify/2` carries its sum,
`{frame, Bytes, Sum}` with `Sum` a sum or `none`. Every Ethernet frame
has its sum by then, since the interface's merge sums each frame that
came without one
([design-network-fastpath.md](design-network-fastpath.md#the-merge)); a
reassembled datagram and every loopback packet carry `none`, and so does
a datagram on the DHCP client's path, which leaves the frame before the
IP layer does. Ethernet decoding strips the
link header, which the sum does not cover. The IP layer decodes its
header as before, and IPv4 still checks its header checksum over the
header's own 20 to 60 bytes, which it reads to decode them anyway. The
upper layer's sum is then one pure function of `erx_net_sum`:

```erlang
span(Packet :: binary(), Sum :: 0..16#ffff, Start :: non_neg_integer(),
     Length :: non_neg_integer()) -> 0..16#ffff.
```

It returns `Sum` less the sum of the bytes before `Start` and less the
sum of the bytes after `Start + Length`, by one's-complement
subtraction. When the bytes after start at an odd offset, their sum is
byte-swapped first (RFC 1071, section 2(B)). An IPv4 header whose
checksum has been checked sums to 16#ffff, one's-complement zero, so
the packet's sum is also the sum of the bytes after the header: the
IPv4 path passes those bytes with `Start` 0, and its header, options
included, is not read again. An IPv6 header has no checksum, so the
IPv6 path passes the packet with `Start` 40 plus `hdrlen`, the extension
headers the IPv6 walk passed, which are headers the decoder has just
read. `Length` is the upper layer's length, and `Start` is even. The bytes after are an Ethernet frame's
padding, at most 26 bytes behind an IPv4 packet and 6 behind an IPv6
one. A frame whose IP length leaves more bytes behind it costs a pass
over those bytes, which is never more than summing the frame.
`erx_net_input`'s pending value carries the bytes of the layer above IP
with their sum. The UDP decoder over IPv4 cuts its datagram at the UDP
length, and it takes the cut's sum with `span/4` as well.

`verify/1` hands the sum to the decoder above IP:
`erx_tcp_wire:decode(PseudoSum, Segment, Sum)`, and likewise for UDP,
ICMP and ICMPv6. Each decoder checks
`erx_net_sum:add(PseudoSum, Sum) =:= 16#ffff` when `Sum` is a sum, and
`erx_bytes:inet_csum(PseudoSum, Segment) =:= 16#ffff` when it is `none`,
then decodes as before. ICMPv4 has no pseudo-header, so its decoder
takes the message and its sum alone, `erx_icmp4_wire:decode(Message,
Sum)`, and checks `Sum =:= 16#ffff`. Each decoder keeps its form without
the sum, which is the form with `none`, for callers that hold no sum,
such as tests. The decoders still make every segment, datagram and ICMP record
after checking a checksum. Only where the sum comes from changes.

One's-complement arithmetic has two zeros, 0 and 16#ffff. A fold of a
positive total is never 0. So every sum derived by subtraction or
addition from a nonzero sum lies in 1..16#ffff, with zero written
16#ffff, which is the form the checks compare with. A frame's network
sum is nonzero whenever it reaches `verify/1`, since its IP header's
version is nonzero.

The check stays where [Receiving](#receiving) puts it, after the frame
holds room. For a frame with a network sum the check costs a constant,
so such a frame that fails costs no more than one dropped for want of
room. The work that grows with a frame's length was spent in the copy,
which every frame costs.

**Transmitting.** The TCP encoder takes who finishes:

```erlang
erx_tcp_wire:encode(#tcp{}, Payload :: iodata(), PseudoSum, sender | driver) -> iodata().
```

With `sender`, the field is the complement of the sum over the
pseudo-header, the length, the header and the payload. With `driver`, it
is `erx_net_sum:add(PseudoSum, Len)` and no payload byte is read.
Finishing sums the field along with the rest, so both give the same
bytes on the wire. `erx_net_frame:tcp/3` chooses `driver` when the path
interface's row has `finish` other than `none` and IP will not fragment
the segment, and `sender` otherwise. A delayed segment's packet is
`{csum, Start, 16, Packet}`, with `Start` the IP header's length and 16
the offset of `th_sum`. `address/3` and `link/3` add the link header's
length to `Start` when they put the header in front. Only TCP segments
are delayed. A datagram's checksum is finished by its encoder. So the
frames a datagram socket also hands its own interface as
`{loop, Frames}`, and every packet sent on the loopback interface, are
already finished.

A delayed checksum is finished at each copy and never stored, so
retransmission and segment boundaries need nothing of their own. Output
cuts each segment from the send buffer's binaries afresh at each pass
([Output](#output)), whatever the owner's writes were and whatever an
earlier transmission of the same bytes looked like. The copy of that
pass sums exactly the bytes it sends.

The virtio transport finishes a delayed frame in one of two ways, by its
`finish`:

* `copy`: `erx_device:post_frame(Dev, Tx, Tag, Hdr, {csum, Start, Field, Frame})`
  with a zero `virtio_net_hdr` as `Hdr`, the 12 bytes in front of the
  frame ([design-runtime.md](design-runtime.md#the-device-nif)). The
  NIF copies the frame's bytes before `Start` plainly and the rest
  through `erx_inet_copy_sum`, in one pass, and then stores the
  complement of that sum at `Start + Field`, in network byte order.
  Both offsets must be even, and the field must lie inside the frame.
* `device`: the `virtio_net_hdr`'s `NEEDS_CSUM` flag, `csum_start`
  equal to `Start` and `csum_offset` equal to `Field`, as section
  5.1.6.2 of the virtio specification has a driver ask the device to
  finish a partial checksum.

A frame that is not delayed is posted with `post_frame/5` without the
`csum` wrapper. A delayed frame whose field does not lie inside it is
dropped as `malformed`. Only a bug in framing can make one. A transport
whose `finish` is `none` drops a delayed frame as `malformed`, as every
transport drops a frame shape it does not take.

**Device offload.** On transmit, `VIRTIO_NET_F_CSUM` lets the device
finish the checksum, so the guest spends nothing on it. It fits behind
the same request as the copy, and it needs no trust: a device that
computes a wrong checksum only makes the peer drop the segment, and a
device can corrupt any frame anyway. It is an extension rather than the
core ([Scope](#scope)), because no medium of the test harness reaches
it. The harness's virtio device sits on a QEMU hub port. As far as this
design knows, QEMU offers `CSUM` and `GUEST_CSUM` only when the device's
backend carries virtio-net headers, as a tap or vhost backend does, and
this has not been checked against QEMU's source. The device finishes
only together with device segmentation, which needs `HOST_TSO4` and
`HOST_TSO6` as well, since one `finish` names who finishes both
([design-network-fastpath.md](design-network-fastpath.md#device-segmentation)):
a device that offers `VIRTIO_NET_F_CSUM` alone is finished by the copy,
and the stack is tested on the device path against the copy on a medium
that offers all three bits.
The transport logs which way it finishes at each start (`finish copy`
or `finish device`), so a run shows which path it took.

On receive, the stack never negotiates `VIRTIO_NET_F_GUEST_CSUM`.
Without it the device delivers frames with complete checksums
(section 5.1.6.4). With it, a device may set `DATA_VALID`, a claim the
stack would have to take on trust, or `NEEDS_CSUM`, on a frame whose
checksum field holds only the pseudo-header's sum, which the stack
would have to accept unchecked. The copy's network sum makes both
unnecessary at the cost of the additions, so the stack takes no
checksum claim from any device. A netmap port gives no claim either:
the netmap transport does not accept virtio-net headers, so each slot
holds a bare frame, and neither does a tap device, whose virtio-net
header the tap transport does not use. Both NIFs call the same core.
Receiving returns `{sum, S, Frame}`, and sending finishes a delayed
frame as it copies the frame into the slot or hands it to the kernel.

**Tap.** Over a tap device the kernel makes the only copy, so there is
no copy of ours to sum in. The tap transport's NIF sums each received
frame right after its `read`, and on send sums each frame's payload
slice where it lies as it writes the frame's headers, through
`erx_tcp_cut_header`, in the same call as the `writev`
([The tap transport](#the-tap-transport)). The payload is read once
more than on the other media, while it is in the cache, and no Erlang
process reads it, so its `finish` is `copy`.

**What the stack believes.** The stack believes one thing: the network
sum a transport of `erx_net` hands up, computed by the stack's own C
over the bytes the binary holds. It believes nothing a device or a
host's kernel says about a checksum. This is safe even against a sum
that is wrong. The Internet checksum detects accidents. It
authenticates nothing: whoever can write a frame can write a correct
checksum for it. A wrong sum can make the stack drop a good frame, or
keep one whose bytes changed on the way, and a device can do either by
writing bytes. A wrong sum cannot make a decoder read past what it
checked, because every length is checked against the binary, never
against a sum. What the stack checks for itself is unchanged: every
length and offset, and the IPv4 header checksum over the header's own
bytes.

**Concurrency and failure.** The sum is made in the same NIF call as
the copy, and it travels with its binary as a value. Nothing else holds it, and no process or message is added. A
broken core or a lying transport makes frames fail their check. They
are counted as `bad_sum`, as a corrupted frame is, and `netadmin` and
the inspector show that count.

**Refusals.** `complete/3` with an odd `SumFrom` is `badarg`. So is
`post_frame/5` with an odd `Start` or `Field`, or a field outside the
frame. The transport's own check drops such a frame first, so only a
bug in the transport reaches `badarg`. A delayed frame given to a
transport that does not finish is dropped as `malformed`, and a frame
that fails its check as `bad_sum`.

**Part of the fast path.** The fast path's cut finishes every checksum
as it copies, and its merge reads each frame's network sum, so this
design is part of that one, not a saving judged on its own share
([design-network-fastpath.md](design-network-fastpath.md#the-construction-runs)).
That share was small: with the C primitive loaded, `erx_bytes` held 3.1
percent of the connection's samples on send on the FreeBSD test host.

**Open decision.** *UDP.* Datagrams could be delayed too. That needs RFC
768's rule that a computed zero is sent as 16#ffff in every finisher, and
a device's finisher may not apply it; it also needs the looped frames
finished before they are looped. Recommended: no, until a UDP bulk
workload is measured.

### Loopback

Traffic to the machine's own addresses goes through a loopback interface,
whose driver, `erx_net_loop`, hands each frame it is given back to its
interface process. The loopback interface carries IP packets with no
link header but their zone: the name of the interface that owns the
packet's destination, which the sender's path gives and
`classify/2` gives the packet's addresses
([Classifying a frame](#classifying-a-frame)). Everything else about it
is the same: the same credits, the same interface process, the same step
functions.

## The TCP core

### The control block

The control block is one Erlang record, `#tcb{}`, translated from
`struct tcpcb` (`tcp_var.h`). Where FreeBSD keeps a flag word whose
combinations are not all legal, the record keeps a variant that can only
hold the legal ones:

| FreeBSD | `#tcb{}` |
| --- | --- |
| `t_state` | `state`, one of `closed`, `syn_sent`, `syn_received`, `established`, `close_wait`, `fin_wait_1`, `closing`, `last_ack`, `fin_wait_2`, `time_wait` |
| `TF_SENTFIN`, `TF_NEEDFIN` | `fin`: `none`, `queued` or `{sent, Seq}` |
| `TF_REQ_TSTMP`, `TF_RCVD_TSTMP`, `ts_recent`, `ts_recent_age`, `ts_offset` | `ts`: `off`, `{requested, Offset}` before the handshake completes, or `#ts{recent, recent_age, offset}` |
| `TF_REQ_SCALE`, `TF_RCVD_SCALE`, `snd_scale`, `rcv_scale` | `wscale`: `off`, `requested` before the handshake completes (the shift asked for follows from `sb_max`), or `{SndShift, RcvShift}` |
| `TF_SACK_PERMIT` | `sack`: `off`, `requested` or `on` |
| `TF_FASTRECOVERY`, `TF_CONGRECOVERY` | the congestion module's `#ccv{}`: `fast_recovery` and `cong_recovery`, two flags, since all four combinations are legal: an ECN mark at or past the recovery point leaves congestion recovery and keeps fast recovery, and congestion modules read and set them as FreeBSD's do through `CCV(ccv, t_flags)` |
| `snd_recover` | `snd_recover`, an unwrapped integer, which the loss module reads in `#loss_ack{}` |
| `t_timers[]` | `send_timer` and `#deadlines{}` |
| `t_rxtshift` | `rxtshift`, kept when the send timer stops |
| `snd_una`, `snd_nxt`, `snd_max`, `snd_wl1`, `snd_wl2`, `iss`, `rcv_nxt`, `rcv_adv`, `last_ack_sent`, `irs` | the same names, unwrapped integers |
| `snd_cwnd`, `snd_ssthresh` | the congestion module's `#ccv{}`, as FreeBSD's `struct cc_var` |

Options negotiated in the handshake (MSS, window scaling, timestamps,
SACK, ECN) are set once, when the connection is synchronized, and never
change afterwards.

The record keeps what an established connection's data and
acknowledgements change, about 38 fields, and holds in one field a
second record, `#tcb_conf{}`, with what only the handshake, an option, a
path change or the owner's requests change, so a stage that updates the
control block copies the small record
([design-network-fastpath.md](design-network-fastpath.md#the-control-block-hot-and-cold)).

### Events and the step

```erlang
-type event() ::
      {segments, [segment()]}                % from the interface, in order
    | {user, erx_tcp_user:request()}         % connect, send, recv, close, ...
    | {expired, Now :: integer()}            % a timer hint
    | {icmp, erx_tcp_icmp:report()}          % unreachable, too big
    | {buffer, Kind :: snd | rcv, Bytes :: non_neg_integer() | refused}.

-type action() ::
      {transmit, [outgoing()]}
    | {deliver, iodata()}
    | {notify, eof | closed | {error, atom()} | {ready, [readiness()]}}
    | {reply, gen_server:reply_tag(), term()}
    | {reserve_buffer, snd | rcv, Bytes :: non_neg_integer()}
    | {reset, outgoing()}                    % within the interface's RST limit
    | charge_rst                             % count one RST against that limit
    | {reinject, segment()}
    | finish.

-type segment() :: {#tcp{}, Payload :: binary(), IpEcn :: 0..3,
                    LinkCast :: unicast | broadcast | multicast}.
-type outgoing() :: {#tcp{}, #{ecn := 0..3, df := boolean()}, Payload :: [binary()]}.
```

A segment carries the ECN field of the IP header it came in, which
`erx_tcp_ecn` reads, and the link cast of its frame, for which the step
answers no segment with a `reset` unless its frame was link unicast, as
`tcp_dropwithreset` sends nothing for a link-layer broadcast or
multicast (`tcp_input.c:3450-3451`), and which a reinjected segment
takes back to its interface. An outgoing segment carries the two IP
header fields TCP decides per segment, as `tcp_output` sets them: the
ECN field, ECT(0) on new data, and don't-fragment, set on IPv4 while
path MTU discovery runs and the maximum segment is above `tcp_minmss`
(`tcp_output.c:1487-1500`) and never on IPv6, where `tcp_output` asks
`ip6_output` for no `IPV6_DONTFRAG`, so a segment over the MTU is
fragmented (`tcp_output.c:1455-1458`, `ip6_output.c:1149-1153`);
`erx_net_frame` builds the rest of the IP header from the path.

A RST that answers a segment (`tcp_dropwithreset`) is
a `reset` action, which the interface sends only within its RST rate
limit (`badport_bandlim`). A challenge ACK to a SYN or an ACK, sent or
not, is preceded by `charge_rst`, as `tcp_challenge_ack_check` charges
that limit: the segment would have drawn a RST had it named no
connection, so the limit does not tell a blind sender whether it did.
A challenge ACK to a RST charges nothing, a departure: a RST that names
no connection draws nothing, so FreeBSD's charge tells the sender its
RST landed in a window, the side channel of CVE-2016-5696.

`erx_tcp:step/3` is the only entry. It dispatches the event to the module
that translates the FreeBSD code for it, then runs output, as
`tcp_do_segment` ends by calling `tcp_output` when an ACK or data is due.
The only other entry is `erx_tcp:rcvd/2`, for bytes that left the
receive buffer: FreeBSD's `tcp_usr_rcvd` calls `tcp_output`, and what
output sends because of them is a window update past the receiver's
silly window avoidance (`tcp_output.c:655-692`). The connection
process asks it first and steps `rcvd` only when output would send: a
window update, an owed ACK, or a segment its last pass held back because
the step's credit was spent (ENOBUFS), which output records in the control
block (`stopped_short`) so the next read sends it as FreeBSD's does.
Otherwise the bytes come off the control block without a step, and what
such calls take off adds up against the same advertised edge, so it
reaches the update and the window does not stall. The rest of what output
reads outside the control block may have changed since the last step: the
cut of the congestion window after idle, and data a missing route held
back once the route returns, come at the next step or the retransmission
timer.

The user requests are FreeBSD's `pr_usrreqs` for a connected stream:
`connect`, `send`, `rcvd` (so many bytes left the receive buffer, pushed
to the socket process, which reopens the window), `shutdown`, `close` and
`abort`. The socket layer's buffer, the bytes not yet pushed, belongs to
the connection process, and the control block counts them so that the
advertised window follows them; the rest of the socket layer, the owner,
the active mode, packet framing and the bytes pushed but not yet
presented, belongs to the socket process in the owner's domain
([The socket process](#the-socket-process)). A `send` carries no
caller and never waits: it brings bytes the socket process sent within
the send credit the connection granted, which always fit the send
buffer, as `sosend` hands `tcp_usr_send` only what `sbspace` has room
for, and the wait for room is the socket process's. A request that
waits carries its caller, and the step answers it from the state it
reaches, after output: `connect` once the connection is established,
and every waiting caller with the error when the connection ends. A connection
that `tcp_close` ended (FreeBSD's `INP_DROPPED`, the record's `ended`) is
done, which a new control block in CLOSED is not: the step runs output
only for a connection dropped after it received a SYN, so that output is
the RST of `tcp_drop`, then tells the socket process how it ended and returns
`finish`. No stage has to remember any of this, since it follows from the
state.

A buffer grows only through the grant. When `tcp_mss` rounds the buffers
up to whole segments, or autosizing grows the send buffer, the step
returns `{reserve_buffer, Kind, Bytes}` and changes nothing; the
connection process asks its grant
([Sockets act for one domain](#sockets-act-for-one-domain)) once it has
performed the step's other actions, and steps the answer: `{buffer,
Kind, Bytes}` sets the buffer, and `{buffer, Kind, refused}`, past the
grant's `buffers` limit, leaves it as it is.
Send autosizing is `tcp_sndbuf_autoscale` (`tcp_output.c:2123-2178`),
which the step runs once, before output, on the connection as output
finds it: the buffer grows by `tcp_autosndbuf_inc`, 8 KiB, when the
peer's window with a 5/4 fudge covers it, it is 7/8 full, it holds less
than `tcp_autosndbuf_max`, and the send window covers what is not yet
sent. A size past `sb_max_adj`, which `sbreserve` refuses
(`uipc_sockbuf.c:659`), is not asked, and that or the grant's refusal
turns autosizing off for the connection, as FreeBSD clears `SB_AUTOSIZE`
when `sbreserve` fails, so the largest send buffer is FreeBSD's, the last
step at or under `sb_max_adj` (about 1.78 MiB), and a connection whose
grant is full asks no more. A refused rounding of `tcp_mss` to whole
segments turns send autosizing off too, where FreeBSD ignores a failed
`sbreserve` there and keeps autosizing (`tcp_input.c:3903`): so a
connection that opens while its grant is full never autosizes, even once
room frees. A growth the grant reserves is a step of its own, whose
output may grow the buffer again, as each round of `sosend` calls
`tcp_output` in FreeBSD. The chain ends: no bytes join the buffer
within it, since a socket process's bytes arrive only as messages between
steps, and the buffer stops growing once they are under 7/8 of it.

`tcp_do_segment` is about 2,000 lines that mix state handling, ACK
processing and data delivery. It is split by stage, not ported in order.
A segment's step is a pipeline of named stages, each returning
`{continue, Tcb, Seg}` (with any actions), `{goto, Stage, Tcb, Seg,
Actions}` or `{done, Tcb, Actions}`, in the order
`tcp_do_segment` takes them, since the order is visible on the wire (a
RST, for example, is judged before the timestamp check):

1. `lift` the segment into the connection's sequence space
   (`tcp_input.c:1511-1629`): a SYN-ACK in SYN-SENT that acknowledges
   what was never sent is answered with a RST, the window scaled and
   the timestamp echo brought back to our clock. FreeBSD also takes
   `t_rcvtime` and reads the segment's ECN here, before any check
   (`tcp_input.c:1566`, `:1592-1595`); the stack does both once the
   segment has passed them all (in `check_ack`, header prediction, or
   `syn_sent` for an acceptable SYN), so a blind segment that knows only
   the four-tuple can neither keep a dead peer's connection from its
   keepalive timeout, as FreeBSD's own comment there warns, nor cut the
   congestion window with ECE, nor make the connection echo CE or stop
   echoing it. TIME-WAIT's
   segments are `tcp_twcheck`'s
   ([TIME-WAIT](#time-wait)), not the pipeline's.
2. `timestamps`: RFC 7323 section 3.2's presence rules, as
   `tcp_do_segment` applies them before header prediction
   (`tcp_input.c:1692-1729`). On a connection that negotiated timestamps,
   a segment without one is processed normally when it is a RST or, by
   FreeBSD's default `tcp_tolerate_missing_ts` of 1 (`tcp_subr.c:219`),
   always, and is silently dropped only with that setting off; on a
   connection that did not negotiate them, a timestamp on a segment is
   ignored and the segment processed; FreeBSD still records such a
   timestamp as `ts_recent` and checks PAWS against it, the stack's
   later stages do not see it. The stack keeps the default, so the
   stage drops nothing, and it is a stage so that the branch is FreeBSD's
   and the packet scripts can pin it.
3. `syn_sent`: the receive window, then the handshake cases of
   `tcp_do_segment`'s switch (`tcp_input.c:1958-2140`): SYN-RECEIVED
   answers an ACK of something other than its SYN with a RST; SYN-SENT
   handles RST, negotiates options and moves to ESTABLISHED or
   SYN-RECEIVED, then jumps to `process_ack` or `step6`, FreeBSD's
   `process_ACK` and `step6`. FreeBSD takes a SYN's options in SYN-SENT
   before it judges the segment (`tcp_input.c:1636-1690`); the stage
   takes them once it has accepted the SYN, so a RST or SYN that
   SYN-SENT drops cannot change what the connection asks for, and on a
   simultaneous open both window shifts apply at once.
4. `check_rst`: RFC 5961 section 3, measured from `last_ack_sent`, the
   last acknowledgement number the connection sent, not from `rcv_nxt`,
   as FreeBSD measures it so that a delayed ACK does not move the
   target (`tcp_input.c:2148-2194`): a RST whose sequence number is
   exactly `last_ack_sent` resets; one elsewhere in the window of
   `rcv_wnd` bytes from `last_ack_sent` gets a challenge ACK; with the
   window closed only the exact match counts.
5. `check_syn`: RFC 5961 section 4: a SYN in a synchronized state gets a
   challenge ACK (`tcp_input.c:2196-2215`), and so does one in SYN-RECEIVED
   at or past `rcv_nxt`: RFC 9293 section 3.10.7.4 treats SYN-RECEIVED
   after an active open as synchronized. FreeBSD lets every SYN through in SYN-RECEIVED, where
   the peer's own SYN again lies before `rcv_nxt` and `trim` strips it; a
   SYN at or past `rcv_nxt` names another initial sequence number, and
   FreeBSD would take its data one byte early. FreeBSD also lets that SYN's
   ECE turn ECN on (`tcp_ecn_input_syn_sent`); here a SYN that passed no
   sequence check changes nothing.
6. `paws`: RFC 7323's check against the last timestamp
   (`tcp_input.c:2218`).
7. `trim`: trims the segment to the receive window, as the `todrop`
   blocks do, resets a connection whose owner closed when data arrives,
   and takes `ts_recent` (`tcp_input.c:2247-2389`).
8. `check_ack`: RFC 5961 section 5 and the ghost-ACK check, with the
   lower bound of
   [Packets become checked records once](#packets-become-checked-records-once-sequence-numbers-are-integers)
   (`tcp_input.c:2397-2450`); a segment without ACK goes to `step6` in
   SYN-RECEIVED and is dropped otherwise. A segment that goes on has its
   ECN read here.
9. `ack`: SYN-RECEIVED to ESTABLISHED, which moves `snd_una` past our
   SYN (FreeBSD's `incforsyn` and its `TF_NEEDSYN` block of
   `tcp_input.c:2869` both do so; `#tcb.need_syn` remains for what a
   simultaneous open changes elsewhere: output sends the owed SYN only
   with an ACK due, no window update goes before it, and the peer's FIN
   is acknowledged with a delay); an acknowledgement of what was never
   sent dropped with an ACK; the loss module's `ack` callback, whose
   `drop` ends the segment with `snd_una` where the send log put it;
   with nothing new acknowledged, a jump to `step6`, as FreeBSD does.
   `process_ack`, from FreeBSD's `process_ACK` label: the undo of a
   spurious timeout, the RTT sample (which resets the backoff count, as
   the undo and leaving persist do), the retransmission timer, the congestion module's
   `ack_received` with appropriate byte counting, the `snd_una` advance,
   the end of recovery, and the transitions when our FIN is
   acknowledged, TIME-WAIT among them (`tcp_twstart`). A timeout is
   spurious when the acknowledgement echoes a timestamp from before the
   retransmission, whose time output records (`t_badrxtwin`,
   `tcp_output.c:848`), for the retransmission alone, where FreeBSD
   records every segment sent while the backoff is 1, so that an ACK we
   send after it cannot make a real timeout look spurious (RFC 3522); the
   undo also clears the timeout's marks in the send log, so the original
   transmissions count in the pipe again. FreeBSD's other rule, an acknowledgement within
   half an RTT on a connection without timestamps, is read only by its
   header prediction (`tcp_input.c:1788`), and the stack's header
   prediction takes the general rule.
10. `step6`, FreeBSD's label: the window update under the SND.WL1/SND.WL2
    rule, then the urgent pointer, processed as FreeBSD does
    (`tcp_input.c:3104`); the urgent byte is held out of band, and
    `gen_tcp`, like stock, has no way to read it. The byte is kept out by
    its sequence number when the bytes are delivered, so the same byte is
    left out whether its segment arrives in order or waits in the
    reassembly queue.
11. `data`: in-order data to the receive buffer, with the delayed-ACK
    decision; out-of-order data to the reassembly queue; the receiver's
    SACK blocks, D-SACK included (`tcp_input.c:3165`), for every segment
    that reaches the stage, so a duplicate trimmed away entirely is
    reported too.
12. `fin`: the FIN transitions to CLOSE-WAIT, CLOSING or TIME-WAIT
    (`tcp_input.c:3319`). The owner learns of the FIN from a
    `{notify, eof}` action, after the `deliver` actions of the data
    before it.

FreeBSD's `drop`, `dropafterack` and `dropwithreset` exits become the
`done` results of the stages. A challenge ACK goes out at most 5 times in
1,000 ms per connection, FreeBSD's per-connection limit
(`tcp_send_challenge_ack`, `tcp_subr.c:2213`; `tcp_ack_war_cnt` and
`tcp_ack_war_time_window`, `tcp_subr.c:139-143`), which keeps the side
channel of a global limit closed. A RST for a segment that names no
connection is limited by the interface's band limiter, FreeBSD's
`badport_bandlim`.

FreeBSD's header prediction, the two common cases of an established
connection (a pure ACK for new data and pure in-order data,
`tcp_input.c:1731`), is a stage of its own between `timestamps` and
`syn_sent`, where FreeBSD has it, with FreeBSD's preconditions (an
established connection, the segment at `rcv_nxt` with only ACK set, the
window unchanged, no retransmission in progress, an empty reassembly
queue, the timestamp no older than the last), so it takes the branch
FreeBSD takes. What it does with a segment it takes is the general
stages' work from `ack` on, finished in one function for each case so
that the control block is built once
([design-network-fastpath.md](design-network-fastpath.md#header-prediction-finishes-its-cases)):
it applies what the checks it skips would set (the receive window,
`ts_recent`, ECN) and what the stages from `ack` on would do. FreeBSD's
fast path repeats that work in a shorter form that leaves different
state (`snd_wl1` and `rcv_up` after a pure ACK, `t_dupacks`, the
spurious-timeout rule); the stack's leaves the general stages' state, so
each effect has one meaning. It is also where a native fast path would
go, if one is ever measured to be needed ([Where C is used, and what is
measured](#where-c-is-used-and-what-is-measured)). Its decision to skip
the checks must not drift from them, so a property test runs generated
segments and states, those header prediction accepts and their near
misses, through the general stages too and requires the same state and
actions wherever header prediction accepts ([The TCP core: exhaustive
exploration](#the-tcp-core-exhaustive-exploration)). A difference it
finds is a bug of one of the two, or a branch FreeBSD really takes
differently, which a packet script then pins.

### Output

`erx_tcp_output` translates `tcp_default_output` (`tcp_output.c:186`) and
`tcp_setpersist` (`tcp_output.c:1744`): what to send and when, Nagle,
sender and receiver silly-window avoidance, window updates, zero-window
probes, options on each segment (`tcp_addoptions`, `tcp_output.c:1794`),
and, from the loss module, what to retransmit first. It takes the
transmit credit from the context and never emits more frames than the
credit allows, and with the context's `{error, ehostunreach}` sends
nothing ([Framing](#framing)). It sizes segments by `t_maxseg`, as
`tcp_output` does, and takes FreeBSD's branch for a segment the
interface's MTU no longer holds where FreeBSD meets it: `ip_output`
refuses a don't-fragment datagram over the MTU with `EMSGSIZE`, and
`tcp_output` then calls `tcp_mss_update(tp, -1, mtu, ...)` with the
route's MTU and sends again (`tcp_output.c:1694-1709`). Here the
context's `mtu` is that MTU, the path's, so before it commits a
segment, output asks whether the segment with its IP and TCP headers
and options fits it under don't-fragment; when it does not, output
lowers `t_maxseg` by `tcp_mss_update` with the context's MTU and sizes
the segment again. A lowered MTU, from a DHCP renewal or the
configuration, therefore lowers `t_maxseg` on the next IPv4 segment
under don't-fragment that would not fit, as in FreeBSD, and nothing is
sent that IP must refuse; an IPv6 segment carries no don't-fragment
([Events and the step](#events-and-the-step)), so one over a lowered
IPv6 link MTU is fragmented, as `ip6_output` fragments it. It produces
`outgoing()` segments; `erx_net_frame` encodes them with the path's
headers. Where per-segment output would send several full segments back
to back from `snd_nxt` under one header, output emits them as one run,
which the copy into the medium cuts into those same frames
([design-network-fastpath.md](design-network-fastpath.md#output-makes-runs)).

### Timers

`erx_tcp_timer` translates the expirations of `tcp_timer.c`:
retransmission with FreeBSD's backoff table and its retransmission limit
(`tcp_timer_rexmt`, `tcp_timer.c:554`), persist (`:486`), keepalive with
FreeBSD's defaults of 2 hours idle and 75 s between probes
(`tcp_timer.h:86-87`; `tcp_timer_keep`, `:380`), 2MSL with an MSL of
30 s (`tcp_timer.h:76`; `tcp_timer_2msl`, `:331`), and delayed ACK
(`tcp_timer_delack`, `:309`). Path MTU black-hole detection is
translated and, as in FreeBSD, off by default
(`tcp_pmtud_blackhole_detect`, `tcp_timer.c:170`).

The 2MSL deadline also ends FIN-WAIT-2, as in FreeBSD. When our FIN is
acknowledged and the receive side is already closed, the deadline is set
to the keepalive's maximum idle time, 8 probes 75 s apart, 10 minutes
(`TP_MAXIDLE`, `tcp_timer.h:143`; `tcp_input.c:3040-3046`;
`tcp_usrreq.c:2724-2731`); when it falls due the connection closes if it
has been idle that long and otherwise waits another 75 s
(`tcp_timer.c:361-366`). So a peer that never sends its FIN holds a
connection for 10 minutes, not for keepalive's 2 hours. FreeBSD's faster
recycling at 60 s (`tcp_fast_finwait2_recycle`, `tcp_timer.c:143`;
`tcp_finwait2_timeout`, `tcp_subr.c:1495`) is off by default, and so it
is here.

The time base is `erlang:monotonic_time/1`, read by the process and
passed in the context. The timestamp option's clock is that time in
milliseconds plus a per-connection offset, a keyed hash of the four-tuple
as `tcp_new_ts_offset` computes it (`tcp_subr.c:3443`), on by default in
FreeBSD (`tcp_ts_offset_per_conn`, `tcp_subr.c:224`).

### The send log, SACK and reassembly

The sender's record of what it has sent is one structure,
`erx_tcp_sendlog`: an ordered map from each sent range's first byte to
`#sent{next, seg, sent_at, transmissions, sacked, lost, rxt}`, `next` being
the sequence number after the range and `seg` the segment size it was
cut at. Because sequence
numbers are integers, the map is an ordinary `gb_trees` keyed by them.
RFC 6675's scoreboard is computed from it, holes, `IsLost`, `NextSeg` and
the pipe included (RFC 6675 section 4), and so is what RACK-TLP needs:
each range's last transmission time is there. `rxt` marks a range
retransmitted during the current recovery, RFC 6675's octets at or below
`HighRxt` kept per range. FreeBSD keeps two structures for this, the
default stack's hole list (`tcp_sack.c`) and RACK's sent-segment hash, and
never unified them, which is one reason RACK is a second stack. Here the
loss modules read and mark the one log, and output takes the next range
to send from it (`NextSeg`). The log is written from RFC 6675, not
translated from `tcp_sack.c`.

Two properties hold by construction. A SACK block marks only the
segments it covers whole, a range's segments being its start plus
multiples of `seg`, and splits the range at their boundaries, so only
the segments the sender cut create range boundaries and a peer cannot
split the log into pieces smaller than what was sent
([design-network-fastpath.md](design-network-fastpath.md#the-send-log-keeps-runs));
a block covering part of a segment is conservative, the segment stays
unSACKed, and neighbouring SACKed ranges merge, so repeated or wide
blocks cannot grow the log. And the unSACKed ranges marked lost are a
prefix of the unSACKed ranges, since `IsLost` is monotone downwards and
`lose/2` takes only an end and marks from `snd_una`, so the pipe is a
constant-time sum of byte counters kept by the one function that changes
a range, `(snd_max - snd_una) - sacked - lost + rxt`, as FreeBSD's
`tcp_compute_pipe` computes it (`tcp_input.c:4149`).

The receiver's side, `erx_tcp_sack`, is written from RFC 2018 section 4
and RFC 2883 section 4, not translated from `tcp_sack.c` (see
"Provenance and notices" for why). It is a pure value beside the reassembly
queue: the ranges the queue holds above `rcv_nxt`, taken from it after
every segment and ordered most recently touched first, the range the
segment touched leading, and the D-SACK block, the lowest part of the
last duplicate segment that the receiver already had, reported once
and first, with the range that contains it second. An
acknowledgement carries at most four blocks, and the encoder keeps as
many from the front as the other options leave room for.
`erx_tcp_reass` translates `tcp_reass`
(`tcp_reass.c:516`): an ordered map of out-of-order ranges with
FreeBSD's overlap trimming and its cap of 100 queued segments
(`tcp_reass_maxqueuelen`, `tcp_reass.c:110`), and the bytes it holds
counted against the receive buffer.

A held payload is counted at the size of the binary it references, not
its own size, since a sub-binary keeps its whole frame alive; a payload
smaller than a quarter of its frame is copied out before it is kept, as
FreeBSD's socket buffers compress small mbufs. So a peer cannot pin many
full frames with one-byte segments.

### Loss detection and congestion control

Two behaviours carry the seams FreeBSD has, with their callbacks taken
from FreeBSD's own interfaces.

`erx_tcp_loss` is the loss-detection part of FreeBSD's function block:

```erlang
-callback init(erx_tcp_loss:params()) -> State :: term().
%% An acknowledgement arrived: mark ranges SACKed or lost, enter or leave
%% recovery, and return the calls the connection makes and whether the
%% rest of the segment is processed.
-callback ack(erx_tcp_loss:ack(), erx_tcp_sendlog:log(), State, Now) ->
    {continue | drop, erx_tcp_sendlog:log(), State, [erx_tcp_loss:event()]}.
%% Sending goes back to snd_una: the retransmission timer expired, the
%% path MTU dropped, or the window shrank to zero after data was sent
%% into it (FreeBSD's tfb_tcp_mtu_chg, widened to every path that moves
%% snd_nxt back, so a module never keeps a stale view of the flight).
-callback rewind({timeout, RxtShift} | mtu | {window, Una, Max},
                 erx_tcp_sendlog:log(), State, Now) ->
    {erx_tcp_sendlog:log(), State}.
%% The window for the output after the last acknowledgement.
-callback allowance(erx_tcp_sendlog:log(), State, erx_tcp_cc:ccv()) ->
    none | {Send :: non_neg_integer(), Keep :: non_neg_integer()}.
%% The module's own deadline, such as RACK's reordering timer.
-callback deadline(State) -> integer() | infinity.
-callback expired(erx_tcp_sendlog:log(), State, Now) ->
    {erx_tcp_sendlog:log(), State, [erx_tcp_loss:event()]}.
```

A loss module never calls the congestion module. Its events are the calls
the connection makes, in order: `{cong_signal, Signal}`,
`{ack_received, dupack}`, stopping the retransmission timer, `TF_ACKNOW`,
and `snd_nxt = snd_max`. `drop` is FreeBSD's `goto drop` after a
duplicate acknowledgement or the entry to recovery. During recovery and
limited transmit the loss module, not the congestion module, sets the
window, as `tcp_input.c` sets `snd_cwnd` around its calls to
`tcp_output`: the connection calls `allowance/3` once after each `ack/4`,
after applying its events; `{Send, Keep}` means that step's output runs
with the window `Send`, measured against the log's pipe, and `Keep` stays
in `#ccv.cwnd` afterwards. What FreeBSD counts in `tcp_output` for the
loss code (`snd_limited`, PRR's `prr_out`) is read from the log instead,
and NewReno's retransmission from `snd_una`, which FreeBSD makes by moving
`snd_nxt` back, is a range marked lost that output resends first.

The default module, `erx_tcp_loss_dupack`, translates the default stack's
duplicate-acknowledgement processing in `tcp_do_segment`: three duplicate
ACKs, SACK-based recovery (RFC 6675 section 5, entered on the third
duplicate or on more than `(DupThresh - 1) * SMSS` SACKed bytes), NewReno
partial ACKs when SACK is off (`tcp_newreno_partial_ack`,
`tcp_input.c:4114`; RFC 6582 section 3.2), proportional rate reduction
(`tcp_do_prr_ack`, `tcp_input.c:4026`; RFC 6937 section 3; on by default,
`tcp_do_prr`, `tcp_input.c:162`), limited transmit (`tcp_do_rfc3042`,
`:172`; RFC 3042), and the timeout's choice between resending the holes
and forgetting the SACK information (`tcp_timer_rexmt`; RFC 6675 section
5.1). Where FreeBSD's code is in `tcp_sack.c` the module follows the RFC:
a partial acknowledgement without SACK blocks during SACK recovery takes
PRR's path (RFC 6937), and "new loss" for PRR (RFC 6937 section 3) is bytes
newly marked by `IsLost`. FreeBSD's lost-retransmission detection
(`tcp_do_lrd`) is not built: no RFC specifies it, and its only description
is its code in `tcp_sack.c`, which erXos does not read. It is the only
loss module. RACK-TLP, which is deferred, would be a second one, `erx_tcp_loss_rack`,
implementing RFC 8985 over the same log; BBR would be a congestion
module beside CUBIC, with pacing added to output.

`erx_tcp_cc` is `struct cc_algo` (`cc/cc.h:145-195`): `init/1`,
`conn_init/1`, `ack_received/3` with FreeBSD's `CC_ACK` and `CC_DUPACK`,
`cong_signal/3` with `CC_NDUPACK`, `CC_ECN`, `CC_RTO` and `CC_RTO_ERR`
(`cc/cc.h:119-128`), `post_recovery/1`, `after_idle/1`, `ecn_pkt/2`,
`newround/2` and `rtt_sample/2`, each a pure function of FreeBSD's
`struct cc_var` as `#ccv{}` and the module's own state. As `cc_var`
holds `cc_data`, the `#ccv{}` holds the module's state and the control
block fields a module reads through `CCV()`; the connection keeps it for
its life and refreshes those inputs before each call.
`ack_received/3` takes the type and the acknowledgement (bytes, segments,
whether the window limits sending); `cong_signal/3` takes the signal and
the acknowledgement number, `none` for a timeout. The `#ccv{}` carries
FreeBSD's two recovery flags, which a module sets as FreeBSD's do and the
connection clears, and from which the loss module's recovery state is
taken. The callers
translate `cc_conn_init`, `cc_ack_received`, `cc_cong_signal` and
`cc_post_recovery` (`tcp_input.c:290-516`) and `cc_after_idle`
(`tcp_output.c:174`). `erx_tcp_cc_newreno` and `erx_tcp_cc_cubic`
translate `cc_newreno.c` and `cc_cubic.c`, CUBIC's fixed-point
arithmetic as integer Erlang. The initial window follows
`tcp_compute_initwnd` (`tcp_input.c:4167`), ten segments under RFC 6928's
limits.

A socket chooses its modules by name with the options `{congestion,
Name}` and `{loss, Name}`, FreeBSD's `TCP_CONGESTION` and
`TCP_FUNCTION_BLK`. Names arrive as binaries and are looked up in a fixed
table of the modules the build contains, so no client name becomes an
atom and no module outside the table can be chosen. The defaults, CUBIC
and `dupack`, come from the `erx_net` application's environment.

### Connection setup

**Active open.** `gen_tcp:connect` asks the grant, which checks its
limits, starts the connection process with `proc_lib:start_link/3` and
waits for its initialisation. The connection claims a local port and its
four-tuple through `erx_net_bind`, the one funnel for both
([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)),
receives from that claim its initial sequence number and timestamp offset,
which `erx_net_bind` computes with `erx_tcp_isn` because it holds the
secrets, sends the SYN and acknowledges its start. No connection holds
the secrets, so no connection's state or crash report can show them. `erx_tcp_isn` translates `tcp_new_isn`
(`tcp_subr.c:3521`): a SipHash of the four-tuple under a secret, plus a
clock. FreeBSD's clock is a shared offset advanced at 1,048,576 a second
and by a random amount per connection, under a lock; the stack's clock is
the monotonic time in microseconds, RFC 6528's own construction, so the
function stays pure and needs no shared counter. The secret is drawn once
at the stack's start, and never reseeded, as FreeBSD's default
`tcp_isn_reseed_interval` of 0 (`tcp_subr.c:286`) leaves it.

**Passive open.** A SYN for a listener is handled in the interface
process, as FreeBSD handles it in the input path, so a SYN flood reaches
no other process and creates no process:

* `erx_tcp_syncache` translates `tcp_syncache.c`: `syncache_add`
  (`:1363`), `syncache_respond` (`:1799`), `syncache_expand` (`:1040`)
  and `syncache_chkrst` (`:615`). Each interface process holds a bounded
  table of half-open connections, 15,360 entries by default, FreeBSD's
  512 buckets of 30 (`tcp_syncache.c:162-163`), with SYN-ACK
  retransmission under FreeBSD's limit and backoff, driven by the
  interface's deadlines.
* Before it looks the SYN up, `erx_tcp_syncache:add/5` drops a SYN to
  or from itself, from or to a multicast address or from the limited
  broadcast, the checks `tcp_input` makes before `syncache_add`
  (`tcp_input.c:1295-1338`) that read the four-tuple alone. A SYN to a
  broadcast or multicast address never reaches it: `erx_net_input`'s
  listener row drops it by the class `erx_ip4` or `erx_ip6` found for
  the destination on the receiving interface, so the broadcast
  addresses of that interface (`in_ifnet_broadcast`) are tested in one
  place, the IP layer's.
* SYN cookies are on, as FreeBSD's default (`tcp_syncookies`,
  `tcp_syncache.c:105`): every SYN-ACK's initial sequence number is a
  cookie (`tcp_syncache.c:1726-1729`): 24 bits of a SipHash-2-4 MAC of
  the connection, the window-scale and MSS indexes, the SACK flag and a
  bit naming which of two secrets made it (`syncookie_mac`,
  `tcp_syncache.c:2194`; the layout at `:2154-2163`). The secrets
  alternate, one replaced every 15 s (`SYNCOOKIE_LIFETIME`,
  `tcp_syncache.h:110`; `syncookie_reseed`, `tcp_syncache.c:2419`), so a
  cookie validates for 15 to 30 s. An ACK that matches no entry is
  checked as a cookie only while the table is paused or if it overflowed
  in the last 15 s, as FreeBSD checks only then
  (`tcp_syncache.c:1053-1056`, `:1095-1110`). FreeBSD records the last
  overflow per bucket (`sch_last_overflow`); the stack has one table per
  interface and records it for the table. Since an overflow pauses the
  table, and FreeBSD's pause covers every bucket, the two differ only in
  the second a first 15 s pause ends: there a valid cookie can complete a
  handshake that FreeBSD, whose bucket for it had not overflowed, would
  refuse. The
  cookie's MAC is required either way. The cookie secrets are
  stack-wide, in `erx_net_tables`, so an ACK that arrives on another
  interface still validates; FreeBSD's MAC also covers the bucket's
  address, which one table has no use for.
* A SYN that finds the table full pauses it, as a full bucket pauses
  FreeBSD's cache (`syncache_insert`, `tcp_syncache.c:367`;
  `syncache_pause`, `:2446`). The table drops every entry, and until the
  pause ends it makes no entry, answers each SYN with a SYN-ACK alone and
  checks every ACK that matches no entry as a cookie. FreeBSD drops the
  full bucket's oldest entry for the new one, but once paused it looks no
  entry up and its timer drops every entry without answering
  (`syncache_timer`, `:485-497`), so dropping them all when the pause
  starts is the same rule with one table for the bucket; the table
  overflows when it holds 15,360 entries, where FreeBSD's first bucket
  fills at 30. A pause lasts 15 s (`TCP_SYNCACHE_PAUSE_TIME`). One that
  starts less than the last pause's own length after that pause ended
  doubles it, up to six times, to 16 minutes
  (`TCP_SYNCACHE_MAX_BACKOFF`); any other lasts 15 s again. The table
  keeps the end of the last pause and its doublings, in whole seconds of
  uptime, and is paused while the uptime is before the end, the test
  `syncache_unpause` makes (`pause_until - time_uptime` no longer
  positive): the pause is a value derived from the step's time and needs
  no timer. FreeBSD makes that test when its callout fires, the pause's
  length after it began, so its pause can end up to a second later. Its
  pause is the stack's; the stack's is the interface's, with its table,
  so a flood on one interface leaves the others' handshakes their
  entries. Until a flood fills the table, each of its entries draws up to
  three SYN-ACK retransmissions to a spoofed source; they stop when the
  pause starts, and while it lasts each SYN is answered once. An entry is
  lost to a flood only as FreeBSD loses it: all at once, when the pause
  starts, after which its handshake completes by its cookie.
* The secrets are context, not state. `erx_net_tables` draws the two
  cookie keys and rotates them every 15 s; the interface process reads
  them, with the timestamp secret, at each SYN or ACK for a listener and
  passes them to `erx_tcp_syncache` in the step's context. Neither the
  table nor an entry holds a key: an entry keeps its cookie and its
  timestamp offset, and those values alone reach the connection in the
  handshake's result. The secrets value keeps its keys in a closure,
  whose environment a crash report does not print.
* A signed (TCP-MD5) SYN or ACK to a listener is dropped: the SYN and
  an ACK under a cookie as a FreeBSD kernel without TCP-MD5 drops them,
  an ACK for an entry where FreeBSD would complete it. A SYN repeated for an entry may
  withdraw ECN but never grant it (`syncache_add`,
  `tcp_syncache.c:1543-1546`).
* When the handshake completes, the interface process takes one unit of
  the listener's accept credit, the free places of its backlog, spawns the
  connection process with its initial state, the handshake's result and
  the completing segment, and inserts the four-tuple into the
  demultiplexing table before it handles its next frame, so no later
  segment of the connection finds neither the syncache entry nor the
  connection. The connection links itself to the listener's grant and
  tells the listener it is ready. With no credit left, the interface
  answers with a RST, FreeBSD's default when a completed handshake finds
  no room (`tcp_sc_rst_sock_fail`, `tcp_syncache.c:215`;
  `tcp_input.c:1115-1135`).

The listener holds connections ready to be accepted and the callers
waiting in `accept`. Closing the listener aborts the connections it still
holds, with a RST, as BSD sockets do.

### TIME-WAIT

TIME-WAIT is a state of the connection process, as FreeBSD 15 keeps it a
state of the full control block (`tcp_twstart`, `tcp_timewait.c:148`).
The process hibernates for the 2MSL period, 60 s, or 20 ms when the peer
is one of the machine's own addresses (`tcp_eff_msl`'s `TCPTV_MSL_LOCAL`,
which the control block's `local_peer` selects, set by whoever makes it),
so it holds only its smallest heap. `erx_tcp_timewait` keeps FreeBSD's
rules (`tcp_twcheck`, `tcp_timewait.c:197`), and the step hands it every
segment that reaches the connection in TIME-WAIT in place of the
pipeline: a RST is dropped (RFC 1337); a new SYN that RFC 6191 allows, by
a newer timestamp or a higher sequence number, ends the old connection:
the process removes its entry and returns the SYN to its interface
process with `{reinject, Segment}`, which looks for a listener as
`tcp_twcheck` returning true makes `tcp_input` do; any other segment
without ACK is dropped; a retransmitted FIN restarts the 2MSL period; and
every segment but a bare duplicate ACK is acknowledged.

A connection in TIME-WAIT does not count as one of its grant's sockets.
It counts toward the grant's `time_wait` limit; past that limit a closing
connection skips TIME-WAIT, as FreeBSD did before 15 when its compressed
time-wait zone was full. This is a departure from 15, which has no limit,
made because every TIME-WAIT process is memory held for one client.

### ICMP and path MTU

The interface process decodes ICMP and ICMPv6 errors and hands each to
the socket its quoted header names, as an owned item. `erx_tcp_icmp`
translates `tcp_ctlinput_with_port` (`tcp_subr.c:3091`): a report whose
quoted sequence number lies outside `snd_una` to `snd_max` is ignored
(RFC 5927); fragmentation-needed and packet-too-big lower the path MTU
through `tcp_mtudisc` (`tcp_subr.c:3594`) and `tcp_mss_update`
(`tcp_input.c:3742`), and only ever lower it, from an MTU raised first to
256 bytes for IPv4 (`tcp_minmss` with its headers, `tcp_next_pmtu`) and
1,280 for IPv6 (`tcp6_next_pmtu`), and the step's output resends the
flight from `snd_una` at the new size; a port unreachable or time exceeded
report in SYN-SENT ends the connection, as `tcp_drop_syn_sent`
(`tcp_subr.c:3559`) does; and every other error is a soft error
(`tcp_notify`, `tcp_subr.c:2580`), ignored for a host unreachable once
established, ending a handshake that has timed out more than three times
after an earlier one, and otherwise reported by the connection's timeout.
The lowered MTU lives in the connection's MSS until the host cache
extension keeps it per destination.

### Defaults kept

| Feature | FreeBSD default | Stack |
| --- | --- | --- |
| syncache and SYN cookies | on (`tcp_syncache.c:105`) | on |
| RFC 5961 | on (`tcp_insecure_syn`, `tcp_insecure_rst`, `tcp_insecure_ack` all 0, `tcp_input.c:197-209`) | always on; no knob |
| RFC 6528 | `tcp_new_isn` | always |
| window scaling and timestamps | on (`tcp_do_rfc1323`, `tcp_subr.c:207`) | on |
| SACK with RFC 6675 recovery | on (`tcp_do_sack`) | on, written from RFC 2018, RFC 2883 and RFC 6675 |
| lost-retransmission detection | on (`tcp_do_lrd`) | not built: no RFC specifies it and its code is in `tcp_sack.c` |
| PRR, limited transmit, IW10 | on (`tcp_input.c:162-178`) | on |
| ECN | 2: accept when the peer asks, never initiate (`tcp_do_ecn`, `tcp_ecn.c:106`) | 2, so a peer that asks for AccECN gets RFC 3168 ECN, as `tcp_ecn_syncache_add` answers it (`tcp_ecn.c:509-537`); like FreeBSD, a SYN-ACK with ECE alone turns ECN on although our SYN did not ask, where RFC 3168 section 6.1.1 would leave it off (`tcp_ecn_input_syn_sent`, `tcp_ecn.c:120`) |
| missing timestamps on a connection that negotiated them | tolerated (`tcp_tolerate_missing_ts`, `tcp_subr.c:219`) | tolerated |
| FIN-WAIT-2 recycling at 60 s | off (`tcp_fast_finwait2_recycle`, `tcp_timer.c:143`) | off |
| delayed ACK | on (`tcp_delack_enabled`, `tcp_input.c:152`) | on |
| buffer autosizing | on (`tcp_do_autosndbuf`, `tcp_output.c:116`; `tcp_do_autorcvbuf`, `tcp_input.c:217`) | on, within the grant's buffer budget |
| CUBIC | default (`cc/cc.c:83`) | default |
| path MTU discovery; black-hole detection | on; off (`tcp_timer.c:170`) | on; off |

## IP, neighbours and UDP

### IPv4 and ARP

`erx_ip4_wire` makes the checks `ip_input` makes before it reads a
packet: version, header length, header checksum and total length, with
the trailing bytes cut at the total length. `erx_ip4` translates the
decisions of `ip_input.c` and `ip_output.c`: the bogus-address checks,
delivery or drop (the
stack forwards nothing), header fields on output, and fragmentation of
datagrams larger than the path MTU. IPv4 options are checked for their
lengths and otherwise skipped, and a packet carrying a source-route
option is dropped, as FreeBSD's defaults drop one that reaches a host
(`ip_dosourceroute` and `ip_acceptsourceroute` both 0,
`ip_options.c:70-80`); skipping the record-route and timestamp options
is a departure visible only in echo replies, which FreeBSD gives the
request's options. `erx_ip4_wire` refuses a packet with a malformed
option, one whose length byte is missing, below 2 or past the header,
and returns the offset of that byte, which `ip_dooptions` makes the
pointer of the parameter problem it answers with (`ip_options.c:132-138`),
so `erx_ip4` can send the same answer after its loopback check.
`erx_ip4` also drops a TCP segment from 0.0.0.0, the check
`tcp_input_with_port` makes (`tcp_input.c:751`): it is the one decision
that sees a segment's IP header before the TCP lookup, and `erx_ip6`
drops one from `::` in the same place (`tcp_input.c:675`).
`erx_ip4_reass` translates `ip_reass.c`, with
FreeBSD's caps on the datagrams in reassembly, the fragments per datagram
and the lifetime of a queue, all charged to the interface. It and
`erx_ip6_reass` share one table, `erx_ip_reass`, a pure value the
interface process keeps per family, with its deadline among the
interface's others. Its caps are FreeBSD's where FreeBSD fixes them: 16
fragments per IPv4 datagram and 64 per IPv6 one (`maxfragsperpacket`,
`ip6_maxfragsperpacket`), and lifetimes of 30 and 60 seconds
(`ipfragttl`, `IPV6_DEFFRAGTTL`). Where FreeBSD derives them from the
machine's mbuf clusters, an interface holds at most 1,024 datagrams,
1,024 fragments and 2 MiB, FreeBSD's values at 32,768 clusters of
2 KiB. A held fragment counts at the size of the binary it keeps alive,
and one under a quarter of that is copied out first, as for
`erx_tcp_reass`; the header kept from a datagram's offset-0 fragment
counts at its length and keeps no frame alive. A fragment that starts a
new datagram past the datagram cap pushes out the
oldest IPv4 datagram (`ipq_reuse`) and is dropped for IPv6
(`frag6_input`). A completed datagram leaves the table as a packet, the
first fragment's headers without fragmentation in front of the whole
data, and passes the codec and the input decisions again, as FreeBSD
requeues it, so the decoder stays the only maker of a received record
and the IPv6 headers after the fragment header are walked as any
others. `erx_icmp4`
translates `ip_icmp.c`: echo replies, but never to a broadcast or
multicast destination, and errors generated within FreeBSD's limit of
200 a second (`icmplim`, `ip_icmp.c:84`), moved by a jitter of up to 16
either way that is drawn again from the interface's generator each time
the limit is reached, as `badport_bandlim` moves it for every limit it
keeps, RSTs to closed ports included (`icmplim_jitter`, `ip_icmp.c:93`;
`icmplim_new_jitter`, `:1107`), so the limit cannot be used to count
which probes reached open ports. The limits are `erx_net_bandlim`'s, a
pure part of the interface's state with one one-second window for each
kind of answer, as `badport_bandlim` keeps them. A timestamp reply
carries the milliseconds since midnight UTC (`iptime`), which the
interface's loop reads from the wall clock and passes in the
context. Redirects are accepted by
FreeBSD's rules, as its defaults accept them (`drop_redirect`,
`ip_icmp.c:128`; `icmp6_rediraccept`, `icmp6.c:125`): each becomes a
host route of the interface with FreeBSD's expiry (`icmp_input`'s
redirect case, `ip_icmp.c:664`; `rib_add_redirect`, `net/route.c:190`;
`icmp6_redirect_input` for IPv6), and the interface holds at most 64
such routes, dropping new redirects past that, a bound FreeBSD does not
have, for the reason the router and prefix lists have theirs
([IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)).

The identification field follows `ip_fillid` (`ip_id.c:241`): zero on a
datagram with DF set, which RFC 6864 allows and FreeBSD's default
`ip_rfc6864` of 1 does (`ip_id.c:99`), so a TCP connection, which sets
DF for path MTU discovery, sends no identification at all; and a random
value on any other datagram. That is a departure from FreeBSD's default,
a counter shared by every flow (`ip_random_id` 0, `ip_id.c:102`): a
shared counter is state with many writers, and it tells an observer how
much the machine sends to anyone, which an idle scan exploits. The value
is two bytes of the generator of the owner that builds the datagram: a
datagram socket for its datagrams, the interface for its own ICMP
messages. FreeBSD's random mode also refuses a value
among the last 8,192 it gave (`ip_randomid`, `ip_id.c:214`); the stack
keeps no such history, since across owners it would be a table with many
writers and within one it would cost each socket 16 KiB, and a repeated
value matters only between two fragmented datagrams to one destination
within its reassembly lifetime. IPv6 fragment headers carry a random
identification, as `ip6_randomid` gives them (`ip6_output.c:1247`),
drawn the same way.

`erx_arp` translates `if_ether.c`: the entry states, requests retried 5
times (`arp_maxtries`, `if_ether.c:102`), entries kept 20 minutes once
resolved (`arpt_keep`, `if_ether.c:100`), 16 frames held per unresolved
entry, gratuitous ARP and FreeBSD's rules for which replies may create
or update an entry. The table has a bound per interface, 1,024 entries;
past it the oldest unresolved entry is evicted, else the oldest resolved
entry the protocol lets go, and when there is neither, no entry is
made. ARP lets go of any resolved entry no transmitter has hinted in its
last seconds; the IPv6 neighbour cache keeps the same bound and lets go
only of a stale entry no transmitter has hinted (RFC 4861 5.3), keeping
reachable, delay and probe entries. Only an entry this host creates to resolve a neighbour makes room so;
an entry learnt from an unsolicited ARP request or neighbour
solicitation takes only free room and evicts nothing, as FreeBSD's
`lltable` limit, `llt_maxentries`, refuses every new entry once
reached (neither protocol sets it there, so FreeBSD's tables are
unbounded). An on-link sender cycling through spoofed sender
addresses in ARP requests or solicitations therefore pushes out
nothing. One that sends packets drawing a reply (an echo request, a
segment to a closed port) still makes this host resolve each
spoofed source, and those resolutions do make room, a residual
`TODO.md` records. Both tables
are one module, `erx_lltable`, as FreeBSD's `lltable` serves both: a
keyed map ordered by deadline, whose `publish` and `unpublish` actions
for the transmit path follow from each change of an entry, so neither
protocol can change an entry without publishing it. `erx_arp_wire` accepts the two
Ethernet hardware types (`ARPHRD_ETHER` and `ARPHRD_IEEE802`) with 6-byte
addresses and refuses every other. `arpintr` also passes InfiniBand and
FireWire packets on (`if_ether.c:691-720`), and `in_arpinput` drops
those whose address length is not the interface's; so on an Ethernet
interface FreeBSD answers a packet typed FireWire that announces 6-byte
addresses, a hardware type no interface of this stack has, which the
stack refuses.

### IPv6, neighbour discovery and autoconfiguration

`erx_ip6` translates `ip6_input.c`, `ip6_output.c`, `dest6.c` and
`route6.c`: the fixed header with its payload length checked and the
trailing bytes cut, a bounded walk of the extension headers (hop-by-hop
and destination options parsed and skipped by their option types'
rules, routing header type 0 refused as RFC 5095 requires, an unknown
routing type with segments left zero ignored, a zero payload length
and a jumbo payload option dropped silently, as RFC 2675 is gone upstream),
and the first fragment required to hold the whole header chain (RFC
7112). `erx_ip6_reass` translates `frag6.c`, with RFC 5722's rule that an
overlapping fragment discards the whole datagram, and FreeBSD's caps.
`erx_icmp6` translates `icmp6.c`: echo, errors within their rate limit,
packet-too-big. Its limits are `icmp6_ratelimit`'s, one window for each
kind of answer at 100 a second (`icmp6errppslim`, `icmp6.c:2725`) moved
by a jitter of up to 8 either way (`icmp6lim_jitter`), kept in
`erx_net_bandlim` beside the IPv4 limits. As for IPv4, `erx_ip6`
decides once whether a datagram may be answered, and nothing answers a
packet to a multicast address: FreeBSD answers an echo request to a
multicast group, and a parameter problem about an option whose type
asks for one even then (`icmp6_error`, `icmp6.c:268`), which a host
has no reason to do.

A neighbour-discovery message that came in fragments is dropped (RFC
6980), as FreeBSD drops one whose mbuf carries `M_FRAGMENTED`
(`frag6.c:286`; `nd6_nbr.c:146`, `:674`; `nd6_rtr.c:183`, `:384`;
`icmp6.c:2184`). A reassembled packet carries no fragment header, so
the interface tells `erx_ip6` whether reassembly rebuilt the packet it
hands in, and `erx_ip6` drops a router or neighbour message, or a
redirect, that reassembly rebuilt or that carries an atomic fragment
header, before `erx_nd6`, `erx_nd6_rtr` or `erx_icmp6` sees it. The
type it reads is not yet covered by the ICMPv6 checksum, which can only
turn a drop for a bad checksum into this drop.

`erx_nd6` translates `nd6.c` and `nd6_nbr.c`: the neighbour cache's
states with unreachability detection, neighbour solicitations and
advertisements accepted only with a hop limit of 255 (RFC 4861),
and 16 frames held per unresolved neighbour; a solicitation or
advertisement about a tentative address goes to `erx_nd6_dad`, which
translates the detection of `nd6_nbr.c` (RFC 4862 with RFC 7527's
nonces): one probe after the random delay below, a decision one
retransmission interval later, and more probes while only the
interface's own probes come back. Like FreeBSD it decides at the end of
the probes, not at the first answer. The interface stops the detection
of an address it removes and, as RFC 4862 5.4 asks, of every tentative
address when its link goes down, and starts them again when it comes up.
`erx_nd6_rtr` translates `nd6_rtr.c` and `in6_ifattach.c`:
router solicitations, router advertisements, the default-router and
prefix lists with their lifetimes, and stateless address
autoconfiguration (RFC 4862). The interface joins the all-nodes and
solicited-node groups and sends the MLDv2 reports those groups need, so
switches that snoop MLD forward neighbour solicitations; the rest of
multicast is `erx_mcast` ([Scope](#scope)). Redirects are accepted as
for IPv4, by RFC 4861's rules, which `icmp6_redirect_input` checks.

The random values of neighbour discovery are FreeBSD's, drawn from the
interface's generator. The reachable time lies between half and one and
a half times its base, as `ND_COMPUTE_RTIME` bounds it (`nd6.h:196`), and
the stack draws it uniformly over that interval with `uniform/2`.
FreeBSD ANDs a random word with a mask that is not a power of two, which
is not uniform and gives whole seconds: a departure in timing alone,
within FreeBSD's interval. The other values are the delay
of up to one second before a new address's MLD report and duplicate
address detection (`in6_update_ifa_join_mc`, `in6.c:696`;
`in6_broadcast_ifa`, `in6.c:1164`; `MAX_RTR_SOLICITATION_DELAY`,
`nd6.h:179`); and the nonce of each detection probe, RFC 7527's enhanced
detection, which FreeBSD enables by default (`dad_enhanced`,
`nd6_nbr.c:104`; `nd6_dad_ns_output`, `nd6_nbr.c:1587`). A connection
opened over IPv6 takes a random flow label at its start, as FreeBSD's
default `ip6_auto_flowlabel` of 1 gives one (`in6_proto.c:163`;
`in6_pcbconnect`, `in6_pcb.c:516-520`), and a SYN-ACK carries the low 20
bits of its cookie, as `syncache_add` sets them
(`tcp_syncache.c:1730-1737`).

The default-router list holds at most 16 routers and the prefix list at
most 16 prefixes per interface, and each autoconfigured address belongs
to one listed prefix. A router advertisement that would add a router or
a prefix past its bound is ignored for that entry and counted, while
listed entries keep refreshing their lifetimes, so an on-link sender
that fills the lists first can keep later routers out but cannot evict a
router already listed. FreeBSD has no such bound, and RFC 4861 lets a
router's entry live up to 9,000 s, so without one any on-link sender
that passes the hop-limit rule grows the lists at the ingress bucket's
rate; this is a departure for requirement N4, as the TIME-WAIT limit is.

Interface identifiers are RFC 7217's stable, opaque identifiers
(`in6_get_stableifid`, `in6_ifattach.c:342`), by default, where FreeBSD's
default derives them from the MAC address (EUI-64; `ip6_use_stableaddr`
0, `nd6_rtr.c:97`). The identifier is FreeBSD's HMAC-SHA-256 of the
prefix, the interface's name and its duplicate-address-detection
failures, keyed with a secret of the machine where FreeBSD keys it with
the host's UUID, so it is the same on every boot for one network and
unrelated across networks, and no IPv6 address names the hardware
([Decisions](#decisions), 2). The secret is a machine key of 32 random
bytes, which the vault makes at installation and keeps with the
machine's other keys across boots and updates
([design-system.md](design-system.md#the-vault)). As with every key the
vault holds, the key never enters the domain that uses it: the system
domain grants the network domain a key facet whose one purpose is this
identifier, and `erx_nd6_rtr` asks it for the HMAC of each prefix,
interface and failure count, once per address it forms. The message is
FreeBSD's without the host UUID, which is the key here: the prefix's
first 64 bits, the interface's name, the failure count as 8
little-endian bytes and an offset byte, raised and asked again while the
identifier falls in a reserved range (`validate_ifid`). The link-local
address is formed the same way from `fe80::/64`. Router solicitations
follow RFC 4861 section 6.3.7, which FreeBSD leaves to `rtsold`: after a
random delay of up to a second, at most 3, 4 seconds apart, until an
advertisement with a router lifetime arrives. While the vault
answers `unavailable`, as it does without its partition, the interface
forms its addresses from random identifiers for that boot, as RFC
8981's temporary addresses are formed, and logs that it did, so an
address is never derived from the MAC address and is stable whenever the
vault serves.

`erx_in6_src` translates `in6_src.c`, RFC 6724's source address
selection, with the labels of RFC 6724's default policy table, which
FreeBSD's `rc.d/ip6addrctl` installs at boot over the kernel's empty
one, and with public addresses preferred over temporary ones, as
FreeBSD's default `ip6_prefer_tempaddr` of 0 prefers them where RFC 6724
prefers temporary ones. IPv6 sockets are IPv6-only by default, as FreeBSD's
`ip6_v6only` is (`in6_proto.c:169`), and `{ipv6_v6only, false}` admits
IPv4-mapped addresses.

### Addresses and routes

An interface process owns its addresses and the routes learnt on it,
from its static configuration, router advertisements or its DHCP client,
and publishes them as rows of the address and route tables, each row
keyed by the interface. `erx_net_addr` translates the address checks of
`in.c` and `in6.c` (local, broadcast, scope). `erx_net_route` looks up
the longest matching prefix over the published rows, a small table on a
host; it is erXos's own code, since the stack needs nothing of FreeBSD's
forwarding tables. A sender keeps its path, built by `erx_net_frame`
from the rows, with the configuration generation it was built at, and
checks the generation on every output pass
([What owners publish](#what-owners-publish), [Framing](#framing)).

The network domain's configuration names each interface's mode:
`static` with addresses, routes and name servers; `dhcp`, for which the
link supervisor starts `erx_dhcp4`; and whether IPv6 autoconfiguration
runs, which it does by default. `erx_dhcp4_core` is a pure RFC 2131
state machine with RFC 2132's options and RFC 3442's classless static
routes, written from the RFCs with FreeBSD's `dhclient` as the
behavioural reference, over the message codec `erx_dhcp4_wire`, the only
maker of a received DHCP message, which reads the option overload and
translates `dhclient`'s checks of routes and domain names; `erx_dhcp4` is
its process, a child of the link supervisor
([Decisions](#decisions), 3). Its transaction ids and the randomised
delays and retransmission times of RFC 2131 section 4.1 come from the
generator in its state. As `dhclient` does, the client takes the first
acceptable offer, makes no random wait before its first DISCOVER, counts
a lease shorter than a minute as a minute, and does not probe the
offered address with ARP before using it: the interface announces the
address with a gratuitous ARP when it configures it, and `erx_arp`
reports another host answering for it as a conflict.

DHCP needs to send and receive before the interface has an address,
which FreeBSD's `dhclient` does through BPF. Here it is one fixed path
of the interface process, not a socket, so it needs no exception in
`erx_net_bind`:

* **Sending.** `erx_dhcp4` hands the interface process a DHCP message;
  the interface alone frames it, from `0.0.0.0` or, once bound, from the
  leased address, port 68, to the broadcast address or, when renewing,
  the server's address, port 67. A broadcast takes the path
  `erx_net_frame` gives the limited broadcast on a named interface, which
  needs no route ([Framing](#framing)); a unicast renewal takes an
  ordinary path. No other process can send from `0.0.0.0`.
* **Receiving.** `classify/2` returns an unfragmented UDP datagram to
  port 68 on an interface configured for DHCP as `local`, before any
  address check ([Classifying a frame](#classifying-a-frame));
  once `verify/1` has checked the datagram, the interface gives it to
  its `erx_dhcp4` only
  when its transaction id is the client's outstanding one and its client
  hardware address is the interface's; every other datagram to port 68
  is dropped and counted. These datagrams are unowned traffic and spend
  the interface's ingress bucket.
* **Applying.** A lease is untrusted input: `erx_dhcp4_core` checks every
  option's length and value, and what it applies goes to its own
  interface only, through the interface's own step, as a static
  configuration would: an address and netmask; routes, the classless
  static routes when the server sends them, in which case the router
  option is ignored (RFC 3442), and otherwise a default route to the
  first router; an MTU from option 26, at least 68 and at most the
  device's; and name servers and a search list, from options 6 and 15,
  which the grant's `resolver` operation hands each domain's `inet_db`
  ([Name resolution](#name-resolution)), as `dhclient-script` writes
  resolv.conf's `nameserver` and `search` lines. A route's gateway must
  be reachable on the link, and no route may take the subnet's own
  prefix or a destination inside 0.0.0.0/8, 127.0.0.0/8 or 224.0.0.0/3,
  so a server steers only the traffic RFC 3442 gives it. An ACK counts
  only for the address and server it answers, and a renewal that
  changes nothing configures nothing again.

### UDP

`erx_udp` translates `udp_usrreq.c` and `udp6_usrreq.c`: delivery to
the socket bound most specifically, ICMP errors delivered to a connected
socket, and port unreachable errors within the ICMP limit. A datagram
socket holds received datagrams up to its receive buffer, counted in
bytes, and drops beyond it, as a UDP socket's receive buffer does; it
pushes a datagram whole, only when its socket process's byte credit
covers the datagram's length ([The socket process](#the-socket-process)).
UDP-Lite and encapsulation are not part of the stack, and
multicast delivery is `erx_mcast`'s ([Scope](#scope)).

## The effect layer

The effect layer is the stack's processes: the drivers, the interface
processes, the sockets, the grants, `erx_net_tables` and `erx_dhcp4`.
Each reads its inputs, calls its owner's step and carries out the
actions, and decides nothing a pure function could decide. It is written
once and runs in two places: in the network domain, and on stock OTP
29.1.2 outside erXos, as any OTP application runs. The second place is a
development host, where the stack's interop, impairment and
packet-script tests run without QEMU and as many at once as the host has
cores, and equally any node that wants a TCP/IP stack in Erlang over a
tap device or another medium (N12).

### Two places, four seams

| Seam | erXos's implementation | The portable one | Chosen by |
| --- | --- | --- | --- |
| the medium | the driver's transport `erx_virtio_net`, over the device NIF | the transport `erx_net_pipe`, over `gen_udp` or a test process; `erx_tap`, over a tap device; `erx_netmap`, over netmap's rings | each interface's entry in the `interfaces` key |
| the clock and entropy | `erx_net_clock` over ERTS's monotonic clock and `erx_bytes:entropy/1` | the same; in a test run, the virtual clock and its seeded generator | the `clock` key |
| the per-byte primitives | `erx_bytes` of the `erx` application, BIFs of erXos's ERTS, those of the network over the C of `erx_net`'s `c_src/` | `erx_bytes` of `erx_net`'s `portable/` directory: the same C, loaded from `priv/erx_bytes_nif.so`, and `entropy/1` from `crypto:strong_rand_bytes/1` | the build: one of the two modules is present |
| the runtime | `erx_net_erxos`: the request limit of erXos's ERTS, and `erx_facet` to run a grant | `erx_net_local`, in `portable/`: no envelopes, no limits, and a plain loop that runs a grant's callbacks | the `runtime` key |

The runtime's seam is the behaviour `erx_net_runtime`:

```erlang
-callback serve(MaxRequest :: pos_integer()) -> ok.
    % the calling process takes requests from other domains, each at
    % most MaxRequest in decoded size, the runtime dropping a larger one
    % before it is queued; on erXos every one arrives enveloped with its
    % origin
-callback start_grant(Grantee :: local | {pos_integer(), port(), module()},
                      Limits :: map()) ->
    {ok, pid()} | {error, Reason :: term()}.
-callback children(Interfaces :: [map()]) ->
    [{Id :: atom(), Start :: {module(), atom(), [term()]}}].
    % the runtime's own children of erx_net_sup, each made a permanent
    % worker and started after its tables,
    % grants and interfaces: the grant local, and on erXos the mints
    % of net and network_ctl; Interfaces are the stack's, from which
    % network_ctl's units name the link they act on
```

A grant and every socket call `serve/1` as they start; the
`erx_net:mint_grant/4` of [The grant's contract](#the-grants-contract)
calls `start_grant/2`; `erx_net_sup` starts the runtime's `children/1`
last ([The process tree](#the-process-tree)). The client side, `erx_net_client`, finds its
grant through its own `grant` key, a `{Module, Function, Args}` called
once per socket opened, which answers `{ok, Grant, Origin}` or
`{error, Reason}`. `Origin` is how messages from the grant's domain
arrive: `local` when that domain is the caller's own, so they arrive
bare, and otherwise the domain id their envelope carries. On erXos the
key names `{erx_net_client_erxos, grant, []}`, the client's one module
in an `erxos/` directory of its own, which answers from `erx:cap(net)`
and `erx:owner/1` ([design-domains.md](design-domains.md#erlang-interface));
outside erXos it names `{erx_net, local_grant, []}`, the grant `erx_net`
minted for its own node at start, with `Origin` `local`. The same
module offers `expose(SockProc, Origin)`, which a socket process calls
as it starts when `Origin` is a domain id, after it has set
`trap_exit`: it calls `erx:export(SockProc, [send, link], Origin)`,
naming both rights, since `erx:export/3` sets a holder's rights to
exactly the list it is given and a later encode of the pid widens no
holder ([design-domains.md](design-domains.md#exports)); with `link`
alone, the socket could link to its socket process and send it
nothing. So its socket can link to it and push to it, and a link
exit can never stop it, since it traps exits before any process of
that domain may link ([The socket process](#the-socket-process)).
With `Origin` `local` nothing needs exposing, so the call is never
made outside erXos.

The loopback transport, `erx_net_loop`, is the same in both places.
Nothing else differs: the application, its supervisors, its
configuration keys, its tables and every process module are the same,
and no module asks where it runs. The source is laid out by seam:
`src/` holds the stack, which names no module of erXos's but
`erx_bytes`, which both builds provide; `erxos/` holds
`erx_virtio_net` and `erx_net_erxos`, built only into erXos's images;
`portable/` holds `erx_bytes`, `erx_net_local` and the host
transports `erx_tap` and `erx_netmap` with their NIFs' loaders, built
only outside erXos, so a network domain can never be configured with
the local runtime or a host's medium. A key that names a module the build does not hold stops the
application's start with `{error, {seam, Key, Module}}`. `erx_net_local`
doing nothing for `serve/1` is correct, not merely harmless: no message
outside erXos comes from another domain, so none arrives in an envelope
and there is no lane to limit, and the grant's admission needs no variant of
its own ([The grant's contract](#the-grants-contract)).

`c_src/` holds the stack's C. Beside the tap and netmap transports'
NIFs, built only on a host ([The tap transport](#the-tap-transport),
[The netmap transport](#the-netmap-transport)), it holds the C of
the per-byte primitives: the Internet checksum and SipHash-2-4 cores,
`erx_inet_csum.c` and `erx_siphash.c`, the walk over an iodata argument,
`erx_iodata.c`, the cut of a run and the merge of received segments,
`erx_tcp_cut.c` and `erx_tcp_merge.c`
([design-network-fastpath.md](design-network-fastpath.md)), and, for a host,
the NIF library's functions and table, `erx_bytes_nif.c`. The cores and the
walk are the C that both builds share, and each has one copy. erXos's ERTS
compiles them with its own `erx_bytes` BIFs, `erx_bytes_bif.c`, so there
`inet_csum/2`, `inet_csum_update/3`, `siphash24/2`, `tcp_merge/1` and
`tcp_merge_limit/0` are BIFs; outside
erXos, `c_src/Makefile` (POSIX make, which BSD and GNU make both read)
builds them with `erx_bytes_nif.c`, where the same functions are NIFs, into
`priv/erx_bytes_nif.so` against the headers of the host's own OTP. Each
build reads its terms its own way, through the walk's classify function,
and every limit on iodata is the walk's, so the two accept and refuse the
same iodata; each checks a starting sum, a key and the update's binaries
itself, and one probe judges both. The NIF API copies a binary that
starts at a bit offset whole before its size is known, so the portable
module's functions refuse, before they call a NIF, an argument of more
than twice the walk's limits, by a bounded Erlang walk that copies
nothing; within those bounds every refusal is the NIF's. erXos's BIFs
check the size before they copy. The paths
run one way: erXos's tree reaches into `erx_net`, and `erx_net`'s
C includes only its own headers and `erl_nif.h`, so the package builds
alone on any host with stock OTP and a C compiler. A build step that
copied the C out of ERTS's tree would make a second copy that a release
of the package could ship out of step, and leaving the C in ERTS's tree
would give the package a path into erXos's; the source living in the
package that ships it removes both.

The portable `erx_bytes` has no Erlang fallback. Its `on_load` loads
`erx_bytes_nif` from `code:priv_dir(erx_net)`; when that fails, the code
server logs why, the module stays unloaded, every call to it fails with
`undef`, `entropy/1`'s included, and the stack does not start. Nothing
stands in for the C, so the stack never runs on another implementation
than the one erXos runs, and what a host run measures, over a tap device,
netmap, F-Stack or DPDK, is the stack. One probe of the two modules'
shared contract judges erXos's BIFs in a release and the portable NIFs on
stock OTP, and both answer the same random calls as the Erlang models of the
host tests. `entropy/1` outside erXos is the host's generator,
`crypto:strong_rand_bytes/1`, with the same refusals as erXos's; a
failure of the host's generator raises `crypto`'s error and never
returns other bytes.

Faster media are the other extension point. They are NIF transports
behind `erx_net_driver`, each cutting runs in its copy
([design-network-fastpath.md](design-network-fastpath.md#the-seam)), and
nothing above the driver changes for them: `erx_netmap` reaches
netmap's rings through a NIF of its own
([The netmap transport](#the-netmap-transport)), and an `AF_PACKET` or
DPDK transport would come the same way.

### The driver

A driver is one process per interface, `erx_net_driver`, running a
transport, its callback module. `erx_net_driver` holds everything the
credits and the interface need, written once: the attach, the receive
and transmit credits, the backlog and the link state. A transport holds
only its medium.

```erlang
-callback init(Config :: map()) -> {ok, link_info(), T} | ignore | {error, Reason :: term()}.
-callback event(Msg :: term(), T) -> {[event()], T} | {stop, Reason :: term()}.
-callback transmit(erx_net_frame:frame() | erx_net_frame:run(), T) ->
    {ok | {ok, Taken :: pos_integer()} | full | {drop, Reason :: atom()}, T}.

-type link_info() :: #{link := ethernet | none,
                       lladdr := <<_:48>> | none,
                       mtu := 68..65535,
                       state := up | down,
                       tx_limit := pos_integer(),      % frames waiting at the driver
                       finish := copy | device | none}.  % who finishes a delayed checksum and a run's cut
-type event() :: {frames, [rx_frame()]}                % binary(), {sum, S, binary()}, {Zone, binary()}
               | {link, up | down}
               | writable                            % room to transmit again
               | {dropped, Reason :: atom()}.        % too_long, stranger, malformed
```

`event/2` turns a message the transport's medium sent the process, an
interrupt, a datagram or a far end's frame, into events, and any other
message into none; a frame the transport refuses is a `dropped` event,
which the driver counts by its reason, and a medium that has ended is
`{stop, Reason}` ([Ending](#the-driver)). The driver registers its pid
with `erx_net_tables` under its interface's name, where the interface,
started after it by their link supervisor, finds it.

**Attaching.** The interface process calls
`erx_net_driver:attach(Driver, RxCredit)` in its initialisation, with
its receive credit. The driver monitors the caller and answers
`{ok, link_info(), TxCredit}`, its transmit credit made at `init` with
`tx_limit` as its limit. The interface writes its row's driver pid and
credit, link, link-layer address, MTU and `finish` from that answer, so
those fields have one source
([Checksums in the copy](#checksums-in-the-copy)). A restarted interface attaches again; while no
interface is attached, the driver drops what it receives and counts it
as `detached`.

**Receiving.** A `{frames, Frames}` event holds what one event of the
medium gave: virtio's `complete/3` calls, the pipe's waiting datagrams or
a test's injected frames, a tap or netmap `recv/1`. The driver cuts it
into batches within the merge's limit, `erx_bytes:tcp_merge_limit/0`: a
batch ends at its 256th frame, or at the frame that brings it to 64 KiB
([design-network-fastpath.md](design-network-fastpath.md#the-merge-before-classification)),
and a frame of more than 64 KiB, which no medium's MTU allows, is dropped
and counted as `too_long`.
It hands each batch to the interface as `{frames, self(), Batch}`
against the receive credit, one unit per frame, and drops a refused batch
whole, counted as `no_room`. Since every transport's frames pass this one
cut, the interface's merge never meets more than its limit, whatever a
medium gives at once and whatever a peer floods it with.

**Link changes.** The driver keeps the transport's latest link state and
the last one it told the interface. While the two differ, it hands
`{link, self(), State}` against the receive credit, one unit. Refused,
it tries again after each later message it handles and at a clock hint
it arms 10 ms after each refusal, so a link that goes down and stays
silent is still told once the interface has made room. Only the latest
state is ever told, so a device that flaps its link fills nothing. The interface gives
the change to its `erx_dhcp4`, which on `up` starts again from
INIT-REBOOT, as `dhclient` does on a link change (`state_reboot`,
`sbin/dhclient/dhclient.c:302-309`), and does nothing else: FreeBSD's
IPv6 does nothing on a link event outside its `EXPERIMENTAL` option
(`nd6_ifnet_link_event`, `nd6_rtr.c:339-351`), and `ether_output` tests
only the interface's administrative and driver flags, not its link
(`if_ethersubr.c:337-339`). The link state is the interface's own state,
shown by `netadmin` and the inspector, not a published row, so a
flapping link moves no configuration generation.

**Transmitting.** A sender hands `{transmit, Frames}` against the
transmit credit, one unit per frame, a run taking one for each frame it
holds. The driver gives each frame and run to `transmit/2` in order:
`ok` and `{drop, Reason}` take its units, the second counted by its
reason; `{ok, Taken}` takes the first `Taken` frames of a run and keeps
its tail, `erx_net_frame:run_tail(Run, Taken)`, at the head of the
backlog
([design-network-fastpath.md](design-network-fastpath.md#each-transports-cut));
`full` keeps that frame and those after it in a backlog, which the next
`writable` event resumes. A unit is taken
when its frame leaves the driver, not when its message arrives, so the
transmit credit bounds the driver's mailbox and its backlog together.
The backlog is kept rather than a full device queue dropping the frame:
FreeBSD's drivers queue in front of the device's ring, so a burst
longer than the ring is sent late, not lost, and a TCP sender sees no
loss its peer did not cause. The interface's own frames (ARP and
neighbour-discovery answers, RSTs, SYN-ACKs) share the transmit credit
with its clients' data and have no reserved share of it
([Residuals](#residuals)).

**Ending.** A driver ends when its medium is gone, and its link
supervisor starts the whole link again, rather than a driver living on
over nothing. A transport whose medium has ended, a pipe whose far end
ended, answers `{stop, Reason}` from `event/2`, and the driver ends
with `{shutdown, Reason}`. The driver traps exits, so an exit signal
from what it is linked to other than its supervisor, a port or socket
of its medium, ends it the same way, with `{shutdown, {linked, Reason}}`. A crash ends it
too, a virtio device's broken queue included. Once the driver runs, no
end but its supervisor's own stop (`shutdown`) comes before it has lived
a second, and a driver that has lived longer ends at once. A stop sooner
waits out the rest of the second still answering, its link told
`down`, so that the interface its link supervisor is starting beside it
attaches and the link's start completes; a crash sooner waits in
`terminate/2`. The hold is measured on the host's clock, not
[the stack's](#the-clock), since what it paces is the supervisor's,
which counts the host's seconds. A link start whose interface or DHCP
client fails because the driver ended under it, a crash in the
driver's first second, answers the link as started, and the interfaces
supervisor restarts it like any link whose driver ended, so a driver's
end never fails a link's start, nor the stack's own start at boot.

A medium that fails at every start, a tap device that is gone or a
device that breaks its queue at once, therefore restarts its link at
most once a second. The interfaces supervisor's intensity is
`erx_net_driver:starts_within/1` restarts per interface over its
5-second period, six: OTP's supervisor keeps a restart while its whole
second is within the period of the latest one's, so what it counts
spans less than six seconds, in which a held link starts at most six
times. A dead or hostile device, or a far end that never returns, so
never makes the interfaces supervisor give up and take the stack down,
and with it the network domain; what ends a link faster adds to that count: a transport whose `init`
fails at a restart, whose start fails at once and is retried at once,
since the driver never ran and so is not held (`erx_virtio_net` answers
`ignore` to every failure of its `init`, so on erXos its interface is
only lost until the next boot), or an interface or DHCP client crashing
past the link supervisor's own intensity.
A driver waiting out its hold delays the stack's own stop by at most
the rest of that second. A device that stops completing transmits ends
nothing: its backlog fills, senders are refused against the transmit
credit, and the link stays stuck until the driver's next end.

| Transport | `link`, `lladdr` | `mtu` | `state` | `tx_limit` | `finish` |
| --- | --- | --- | --- | --- | --- |
| `erx_virtio_net` | `ethernet`; the device's address when it offers `VIRTIO_NET_F_MAC`, else a random locally administered unicast address drawn at `init` with `erx_net_clock:entropy/1`, as the virtio specification (section 5.1.5) asks a driver to generate | the device's `mtu` field when it offers `VIRTIO_NET_F_MTU`, else 1,500 | `VIRTIO_NET_S_LINK_UP` of the status field when the device offers `VIRTIO_NET_F_STATUS`, read again at each configuration-change interrupt; else always `up`, as the specification says to assume | the transmit queue's size | `copy`; `device` where the device offers `VIRTIO_NET_F_CSUM` with `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`, an extension |
| `erx_net_loop` | `none`, `none` | 16,384, FreeBSD's `LOMTU` (`if_loop.c:80`) | always `up` | configured | `none` |
| `erx_net_pipe` | `ethernet`; the configured address, which must be unicast with the locally administered bit set, else `init` fails with `{error, {lladdr, Addr}}` | configured, default 1,500, from 1,280 to 9,000, else `{error, {mtu, N}}` | `up` from `init`; the far end's end stops the pipe, and the driver tells the interface `down` while it waits out its hold | configured | `none`; `copy` in the `process` end's offload mode |
| `erx_tap` | `ethernet`; the configured address, checked as the pipe's | configured, checked as the pipe's | `up` from `init`; an error of its descriptor ends the medium, and the driver tells the interface `down` while it waits out its hold | configured, default 256 | `copy` |
| `erx_netmap` | `ethernet`; the configured address, which must be unicast | configured, default 1,500, from 1,280 to 9,000 and within the port's buffer with the Ethernet header | `up` from a successful registration; `down` from an `init` whose registration failed, and while the driver waits out its hold | configured, default the transmit ring's slot count | `copy` |

`finish` says who finishes what the stack leaves unfinished, a run's
cut and a delayed checksum: `copy` for a transport whose copy does it,
`device` for a device that cuts and sums (an extension), and `none` for
the pipe and the loop, whose frames the frame layer finishes
([Checksums in the copy](#checksums-in-the-copy),
[design-network-fastpath.md](design-network-fastpath.md#the-seam)). The
virtio transport hands each frame and run to `erx_device:post_frame/5`,
which walks a frame's binaries itself, at most 64, behind the
transport's `virtio_net_hdr`, cuts a run and finishes a delayed checksum
as it copies, so the transport joins nothing and needs no knowledge of a
frame's layers; it takes receive completions with `complete/3`, which
sums each frame past its Ethernet header. The
loop transport makes each frame `{Zone, Packet}` into `{Zone,
iolist_to_binary(Packet)}`, the one copy a device makes elsewhere, and
returns it as received.

**The pipe.** `erx_net_pipe` exchanges Ethernet frames with one far end
and parses nothing:

```erlang
-type far() :: {udp, Local :: {inet:ip_address(), inet:port_number()},
                     Peer :: {inet:ip_address(), inet:port_number()}}
             | {process, pid()}.
```

Each end carries one Ethernet frame, without its frame check sequence,
per datagram or Erlang message. On every end, a frame
longer than the MTU and the 14-byte Ethernet header is dropped as
`too_long`, and a send the far end cannot take as `refused`.

* **`udp`**, as QEMU's `dgram` network backend carries frames. The pipe
  opens its socket with `{active, 64}` and sets it to 64 again at each
  `udp_passive`, so at most 64 datagrams wait in the driver's mailbox
  and the host's socket buffer is the only queue ahead of it; an event is
  the datagrams waiting, which the driver cuts into batches as it cuts
  every event. A datagram from any other address
  than `Peer` is dropped as `stranger`. UDP has no carrier, so the state
  is `up` from `init` to the end.
* **`process`**, a test. The far end is a pid, or a registered name
  looked up at `init`, so that a restarted driver finds the far end
  registered since. Each frame is a message `{erx_net_pipe, Pid,
  Frame}` in either direction, and a `Frame` that is not a binary is
  dropped as `malformed`, a type check and not a parse. Towards the
  stack a test may also send `{sum, S, Frame}`, with `S` an integer
  from 0 to 16#ffff, which the pipe hands up as it is: the test then
  plays a transport that sums as it copies, a lying one included
  ([Checksums in the copy](#checksums-in-the-copy)). The pipe monitors
  the far end, and its end, or a name with nothing registered, stops the
  pipe and ends the driver. The `process` end is what
  makes a run deterministic: every frame in flight is a message the test
  can see ([The clock](#the-clock)).

QEMU's user networking (slirp) on macOS reaches the pipe through a QEMU
process that runs no machine, `-machine none`, with a `user` backend and
a `dgram` backend joined on one hub (`-netdev hubport`).

#### The tap transport

`erx_tap` exchanges Ethernet frames with a host's tap device, on FreeBSD
the node `/dev/tapN`; other systems' tap devices are added as they are
needed. It is the medium of the runs on the FreeBSD test host, where the
stack and lwIP reach the jails' bridge through tap devices. It lives in
`portable/`, with its NIF's loader `erx_tap_nif`, so it is never in an
erXos image; its C, `erx_tap_nif.c`, is in `c_src/` and built on the
host it runs on, by that host's C compiler, into `priv/`. It runs with
the node's own user and privileges; the tap device's permissions are
the host's setup. Like the pipe, it parses nothing. Two rules carry it,
the netmap transport's, over a file descriptor and without shared
memory:

* *The kernel's copy is the only copy.* `recv/1` reads each frame with
  one `read` into a fresh binary, and `send/2` hands the kernel each
  frame with one `writev` of the frame's headers and its payload's
  binaries, cutting a run frame by frame with `erx_tcp_cut_header`
  ([design-network-fastpath.md](design-network-fastpath.md#each-transports-cut)).
  Each call does a bounded amount of work on a normal scheduler: at most
  64 frames or 64 KiB read, and at most one run or frame written.
* *Each direction has exactly one wake.* For receiving, either the
  descriptor is armed for reading with `enif_select`, or the transport
  has sent itself one `{erx_tap, more}`: never both and never neither.
  For transmitting, either the last `send/2` was taken whole, or the
  descriptor is armed for writing and the driver's backlog waits for the
  `writable` event that the arm's message gives.

**Configuration.** `{erx_tap, #{device := Path, lladdr := Addr}}` or
`{erx_tap, #{fd := Fd, lladdr := Addr}}`, exactly one of `device` and
`fd`, with `mtu` (1,500 when absent) and `tx_limit` (256 when absent),
each checked at `init` as the pipe checks it. With `device`, `init`
opens the device by name for reading and writing, non-blocking and
close-on-exec, with `erx_tap_nif:open/2`. With `fd`, `init` adopts a
descriptor the node already holds open on the device, with
`erx_tap_nif:adopt/2`: the NIF checks that `Fd` is a non-negative C
`int`, takes a close-on-exec copy of it with `F_DUPFD_CLOEXEC` and makes
the copy non-blocking. A descriptor that is not open is refused with
`{fd, Fd, {adopt, ebadf}}`, and a failure after the copy closes the
copy. The handle owns only its copy: the node keeps `Fd`, closing it
leaves the copy open, and each start of the driver adopts a fresh copy
of the same `Fd`. The two share one open file and so its flags, which
makes `Fd` non-blocking too, and the node keeps it so while a handle
lives: a blocking copy would stall the scheduler its `read` runs on.
OTP's `socket:close/1`, for one, makes a socket blocking before it
closes it, so a socket's descriptor is adopted only while the socket
stays open. Either way `init` sends itself the first `more`. The NIF's
handle is a resource that monitors its owner, the driver, and every
call from another process is `badarg`, so the handle has one user and
needs no lock.

Adopting is what lets the node run unprivileged on any host. Opening a
tap device takes privileges a node should not hold, and naming an
already open descriptor by a path needs a file system of descriptors
(FreeBSD's `fdescfs`), which other systems lack or do not give for every
kind of descriptor. Instead a privileged opener opens the tap and hands
its descriptor to the node over a UNIX-domain socket in an `SCM_RIGHTS`
control message, whose `rights` data `socket:recvmsg` hands up as the
received descriptor's number, a native C `int`, or starts the node with
the descriptor inherited and its number in the configuration. The tap
device's permissions then need grant nothing to the node's user. The
tests adopt one end of a UNIX datagram socket pair the same way.

**Receiving.** `recv/1` reads until the device has no frame (`EAGAIN`)
or the batch is full. FreeBSD's tap gives one frame per `read`. Each
`read` asks for the MTU, the 14-byte Ethernet header and one byte more,
so a frame shorter than the header is dropped as `malformed` and one
that fills the buffer as `too_long`. Each frame kept is summed and
leaves as `{sum, S, Frame}`
([Checksums in the copy](#checksums-in-the-copy)). An empty device arms
the descriptor for reading and answers `armed`; a full batch answers
`more`. The answer is `{ok, Frames, Drops, more | armed}`, with `Drops` a
count per reason, and the call charges `enif_consume_timeslice` for the
bytes it read and summed.

**Transmitting.** `send/2` takes a frame, as iodata of at most 64
binaries, a delayed frame or a run. A delayed frame,
`{csum, Start, Field, Frame}`, has its bytes up to the end of its
checksum field copied to the NIF's scratch, where the field is finished
from the sum of the bytes from `Start` on, read where they lie, and the
scratch and the rest of the frame go out in one `writev`
([Checksums in the copy](#checksums-in-the-copy)). It writes frames until the device would block
(`EAGAIN`), then arms the descriptor for writing, and answers `{ok, N}`
for the frames it took, or `full` when it took none. A tap may discard a
frame as a wire loses one: a `write` that takes none of it, which
FreeBSD's `tunwrite` returns while the interface is down, or `ENOBUFS`,
drops that frame, counted as `refused`, and the call goes on.

**Ending the medium.** A `write` that takes part of a frame, end of file
on a `read`, and every other error but `EINTR` answer `{error, Reason}`.
The transport answers `{stop, Reason}` from `event/2` at once for
`recv/1`, and for `send/2`, which `transmit/2` cannot stop the driver
from, through the one `{erx_tap, failed, Reason}` it sends itself, as
the netmap transport does; the driver
ends and is started again with a new descriptor ([Ending](#the-driver)).
The driver's mailbox holds at most one `more`, one read arm's message,
one write arm's message and one `failed`, and the tap's own queue is the only queue ahead
of the driver, so a peer that floods is bounded as the `udp` end bounds
it. The tap's virtio-net header (`TAPSVNETHDR`) is not used, so each
`read` and `write` is one bare frame.

#### The netmap transport

`erx_netmap` exchanges Ethernet frames with a netmap port: a port of a
VALE software switch such as `vale0:erx`, or a network card in netmap
mode, on FreeBSD and on Linux with netmap's kernel module. It is the
medium of the standalone runs that compare the stack with other stacks
on one switch: `pkt-gen`, lwIP over netmap, and FreeBSD's own stack in a
jail whose `epair` joins the switch through netmap's emulated mode. Like
the pipe, it parses nothing. Unlike the pipe, it reaches the frames
where netmap leaves them, in rings of slots and buffers that the kernel
shares with the process, through a NIF of its own. It lives in
`portable/`, with that NIF's loader `erx_netmap_nif`, so it is never in
an erXos image; its C is in `c_src/`. DPDK, which gives no file
descriptor to wait on, would need a different scheduling answer from
the one below.

**The construction.** Two rules carry the design.

* *The NIF is a device NIF for a host's rings.* `erx_netmap_nif` is to
  a netmap port what the device NIF is to a virtio queue
  ([design-runtime.md](design-runtime.md#the-device-nif)). It copies
  each frame once on receive, out of its slot's buffer into a fresh
  binary, and once on transmit, from a frame's binaries, or a run cut
  frame by frame, into slots' buffers, and no binary ever aliases the
  shared memory. Each call does a
  bounded amount of work. Nothing in the shared memory is trusted. Each
  call reads every field the kernel writes once, into a snapshot, and a
  pure C core, `erx_netmap_ring`, turns the snapshot, with the sizes of
  the frames to send, into a plan: which slots hold frames, which are
  dropped and why, and for each copy an offset and length checked to
  lie inside one buffer of the mapping. The NIF copies only what the
  plan names, and the plan is complete before the first byte moves.
* *Each direction has exactly one wake.* For receiving, either the
  port's descriptor is armed for reading with `enif_select`, or the
  transport has sent itself one `{erx_netmap, more}`: never both and
  never neither. For transmitting, either the ring had room at the last
  send, or the descriptor is armed for writing and the driver's backlog
  waits for the `writable` event that the arm's message gives. A send
  that leaves frames in the ring without a sync has one
  `{erx_netmap, flush}` on its way.

The first rule is the memory-safety argument and the second the
liveness and bounds argument; together they remove the list of cases a
ring driver otherwise keeps. A call that cannot keep either rule, for
any reason, answers `{error, Reason}`, and every such answer ends the
medium (*Ending the medium*, below), so no failure leaves the transport
waiting for a wake that will not come. The driver's mailbox holds at
most one of each message the transport causes, since each arm is
one-shot, the receive rule allows one `more`, and the transport keeps a
flag for its `flush` and one for its `failed`; a burst from a peer
cannot fill it.

**Configuration.** An interface's entry names the transport as
`{erx_netmap, #{port := Port, lladdr := Addr}}` with these keys:

| Key | Value | Checked at `init` |
| --- | --- | --- |
| `port` | the netmap port's name: `vale0:erx` for a port of the switch `vale0` (created when it is opened and gone when it is closed), `ix0` for a card | 1 to 63 bytes, the kernel's `NETMAP_REQ_IFNAMSIZ` less its terminator, each an ASCII letter or digit, `.`, `_`, `-` or `:`, else `{error, {port, Port}}`. The kernel reads other bytes of a name as its own syntax (`{` and `}` name a netmap pipe), so such a name would bind some other port rather than fail |
| `ring` | which ring pair of the port to bind, default 0 | below 65,536, else `{error, {ring, N}}` |
| `lladdr` | the interface's Ethernet address. A switch port has none of its own; a card's own address may be given | unicast, else `{error, {lladdr, Addr}}` |
| `mtu` | default 1,500 | 1,280 to 9,000, and with the 14-byte Ethernet header within the port's buffer size, else `{error, {mtu, N}}` |
| `tx_limit` | frames that may wait at the driver; default the transmit ring's slot count | a positive integer, else `{error, {tx_limit, N}}` |

The address is not required to be locally administered, as the pipe's
is, since a card in netmap mode keeps its own; a switch port should
still be given a locally administered one. netmap reports no carrier,
so a card's cable is not seen.

**One ring pair per transport.** The transport registers one ring pair,
`NR_REG_ONE_NIC` with the configured ring, so each interface has one
descriptor, one receive ring and one transmit ring. A switch port has
one pair by default. A card with several queues is set to one queue
pair (on FreeBSD the `iflib` tunables `override_nrxqs` and
`override_ntxqs`, on Linux `ethtool -L`), or becomes several
interfaces, one per pair, which is the stack's extension of one
interface process per receive queue ([Scope](#scope)). One transport
over every ring is not offered: one descriptor over several rings would
put the frames of one flow on whichever transmit ring had room, so a
card could reorder them on the wire, and `poll` reports such a
descriptor writable when any of its rings has room.

**Opening.** `erx_netmap_nif:open(Port, #{ring := N, mtu := Mtu})` runs
on a dirty I/O scheduler, since the registration allocates the port's
memory and may take milliseconds. `init` calls it once, and it does
this, in order:

1. Open `/dev/netmap`, read and write, close-on-exec.
2. Register with `NIOCCTRL`: `NETMAP_API` of the headers the NIF was
   built against, `NETMAP_REQ_REGISTER`, the port's name, and
   `NR_REG_ONE_NIC` with the ring and two flags, `NR_EXCLUSIVE`, so the
   kernel refuses a second registration of the same rings by any
   process, and `NR_NO_TX_POLL`, so a wait for reading does not also
   sync the transmit ring. Every other field is zero: the port's own
   slot and ring counts, a region the kernel chooses, no extra buffers,
   and no `NR_ACCEPT_VNET_HDR`, so a port that would put a virtio-net
   header before each frame refuses, and every slot holds a bare frame.
3. Map the region the answer names, `nr_memsize` bytes, shared, read and
   write.
4. Check the layout. These fields are read once and kept in the NIF's
   handle: the interface descriptor at `nr_offset`, its ring counts, the
   offsets of ring `N` of each direction, and each ring's slot count,
   buffer size and buffer offset. `erx_netmap_ring` checks with checked
   arithmetic that each ring's header and slots lie inside the mapping,
   that each ring carries its ring number and its direction, that the
   slot count is at least 2, and that the buffer size holds the MTU and
   the Ethernet header.
5. Monitor the calling process, the handle's owner.

It answers `{ok, Handle, TxSlots}`, the transmit ring's slot count and
`tx_limit`'s default, or `{error, Reason}`: `{mtu, Mtu}` or `{api,
Kernel, Built}`, which refuse `init`, or else `{Step, Errno}`, or
`{layout, broken}`. The handle is a NIF resource. Every later call
checks that its caller is the owner and is `badarg` otherwise, so the
handle's state has one user and needs no lock.

**Receiving.** `erx_netmap_nif:recv(Handle)` does one batch:

1. `NIOCRXSYNC`, which returns the slots the transport released and
   moves the ring's `tail` past the frames that have arrived.
2. Read `tail` once and check it is below the slot count. Then read each
   slot from the handle's own `head` towards `tail` once: its buffer
   index, its length and whether `NS_MOREFRAG` is set. At most 256 slots
   are read.
3. The core plans the batch from that snapshot. A slot whose buffer lies
   outside the mapping, or whose length exceeds the buffer size, breaks
   the ring, since these are the kernel's own structure, as a virtio
   completion naming no posted buffer breaks a queue. A frame shorter
   than the Ethernet header is dropped as `malformed`, and one longer
   than the MTU and the header as `too_long`, as is every slot of a
   chain that `NS_MOREFRAG` marks (a switch makes one when a peer sends
   a frame larger than one buffer); the handle keeps whether a chain is
   open, so a chain across two calls is dropped whole. Every other slot
   is a frame. The plan stops at 64 KiB of frames or 256 slots.
4. Copy each frame into a new binary through `erx_inet_copy_sum`, which
   sums the bytes past the Ethernet header in the same pass
   ([Checksums in the copy](#checksums-in-the-copy)). Then store the new
   `cur`, then the new `head`, with release ordering. That order keeps
   every pair the kernel reads valid, `head` never past `cur`, even when
   ERTS's poll thread syncs the ring from another thread in the middle.
5. If the plan stopped at its limit with slots left, answer `more`.
   Otherwise the ring is empty after the call's own sync, and the call
   arms the descriptor for reading and answers `armed`.

The answer is `{ok, Frames, Drops, more | armed}`, each frame
`{sum, S, Frame}` and `Drops` a count per reason, or `{error, Reason}`: `broken`, the sync's error number, or
`arm` when `enif_select` answers a negative value, the batch's frames
then going with the medium. The call charges `enif_consume_timeslice`
for the bytes it copied and the slots it read. The transport turns the
answer into one `{dropped, Reason}` event per dropped frame and
`{frames, Frames}`, and on `more` sends itself `{erx_netmap, more}`, so
the interface runs between batches as it does between virtio's.
`init` sends itself the first `more`, so frames that arrived before the
start are read through the same path as every later batch.

**No lost wakeup.** Nothing is lost between a call's sync and its arm,
in either direction. Registering the descriptor with ERTS's poll set
polls it once, through kqueue's attach on FreeBSD and `epoll_ctl` on
Linux, and netmap answers that poll from the rings after a sync of its
own (`netmap_poll`): a poll for reading syncs the receive ring, and a
poll for writing syncs the transmit ring, which with `NR_NO_TX_POLL` is
the only poll that does. So a frame that lands, or a transmit slot the
kernel finishes, between the call's sync and its arm is reported by the
arm itself. This rests on netmap's poll handler, not on anything erXos
controls. The switch run below checks the receive side. The write arm
meets a real kernel only on a card, since a switch port's sync gives
back every slot it sends (`netmap_vp_txsync`); until a test host has a
card in netmap mode, the write arm is tested over the fake ring alone.

**Transmitting.** `transmit/2` drops a loopback frame, which names a
zone, as `malformed`, as every transport does, and once the medium has
failed drops every frame as `refused` without a call. It hands every
other frame and run to `erx_netmap_nif:send(Handle, FrameOrRun)` as it
came: a frame as iodata of at most 64 binaries, which the NIF walks
itself, counting the pieces and their sizes before it copies anything;
a delayed frame, `{csum, Start, Field, Frame}`, whose checksum the NIF
finishes as it copies ([Checksums in the copy](#checksums-in-the-copy));
or a run, which the NIF cuts into its frames through the cut's core
([design-network-fastpath.md](design-network-fastpath.md#each-transports-cut)).
No frame is joined in Erlang, so no frame is copied twice.
`enif_inspect_iovec` is not used: OTP lets the vector it returns hold
more elements than the bound it is given, so its count would be one more
length crossing into C.

The core plans the send from the sizes the NIF counted, or the cut's
plan of a run, and a snapshot of the slots from the handle's `head`. A
frame below the Ethernet header's 14 bytes is dropped as `malformed`
and one above the MTU and the header as `too_long`; each slot's buffer
index, read once, is checked as on receive. When the ring has no room
by the `tail` of the last sync, the NIF syncs once, which sends what is
staged and gives back the slots the kernel is done with, and plans again
from the new `tail`. It copies each frame into its slot's buffer, sets
the slot's length with every flag clear, advances `cur`, then `head`,
and answers one of these:

* `{ok, N}`: the first `N` frames, every frame of a plain frame or of a
  run that fit, are in the ring, not yet synced. When a run did not fit
  whole even after the sync, the NIF has armed the descriptor for
  writing, and its tail waits in the driver's backlog for the `writable`
  event, as after `full`. The transport sends itself
  `{erx_netmap, flush}` if none is on its way. `flush/1` is one
  `NIOCTXSYNC`, so every frame the driver gives the transport before
  that message comes back, from the backlog and the transmits already
  in its mailbox, leaves in one sync, which the transmit credit bounds.
  A switch moves the frames to their destination inside the sender's
  sync, so on a switch port the flush is also the send.
* `full`: no room for the first frame even after that sync. The NIF has
  armed the descriptor for writing, and the arm's message is the
  `writable` event.
* `{drop, malformed}`, `{drop, too_long}`: for a plain frame, as the
  driver counts drops.
* `{error, Reason}`: the sync of a full ring failed (its error number),
  the arm failed (`arm`), or a slot's buffer broke the ring (`broken`).
  What was not taken is dropped as `refused`, and the transport records
  the failure and sends itself one `{erx_netmap, failed, Reason}`, since
  `transmit/2` cannot stop the driver itself.

**Scheduling.** Every call but `open/2` runs on a normal scheduler and
is bounded: `recv/1` at 64 KiB, 256 slots and one sync, `send/2` at one
run of at most 65,535 bytes or one frame of at most 9,014, and one
sync, and `flush/1` at one sync. A
sync is a system call that never blocks, so a dirty scheduler would
cost a switch per batch and buy nothing. No thread of the transport's
own waits: ERTS's poll threads do, and `enif_select` turns readiness
into a message to the driver. Nor does it spin on the ring, which would
hold a core and which netmap cannot use, since `tail` moves only at a
sync ([todo-performance.md](todo-performance.md) weighs latency at low
rates).

**What the shared memory may hold.** The mapping is shared with the
kernel, and with any process that registers a port in the same region:
a switch port has a region of its own, but a host's cards share
netmap's global region, which any process that can open `/dev/netmap`
can map. Such a process is as trusted as the node (the test host gives
`/dev/netmap` to the node's own user alone), and still every field is
treated as a value that may change at any time and may be wrong:

* The fields fixed at registration are read once, at open, checked, and
  kept in the handle; `head` and `cur` are the handle's own, written
  and never read back.
* `tail` and each slot's buffer index, length and flags are read once
  per call, into the snapshot. A buffer is a range of the mapping
  computed with checked arithmetic from the ring's offset, its buffer
  offset (a signed 64-bit value) and the index, and must end within the
  mapping; a length is checked against the buffer size, then the MTU.
* A frame's bytes may change while they are copied. The copy is then
  wrong but within its bounds, the binary made from it never changes
  afterwards, and the stack treats it as untrusted like any frame.
* The C reads no byte of a frame. Error numbers become atoms from a
  fixed table in the NIF (`eacces`, `ebusy`, `einval`, `enoent`,
  `enomem`, `enxio`, `eperm` and the rest of the list), any other
  number stays an integer, and no atom is made from the mapping.

A peer controls a frame's bytes, its length, which is checked, and the
rate, which costs the driver one bounded, preemptible call per batch.

**Ending the medium.** Every `{error, Reason}` the NIF answers means the
medium has ended, and `event/2` answers `{stop, {netmap, Reason}}`: at
once for `recv/1` and `flush/1`, through the `failed` message for
`send/2`. No list of failures is kept; a failed sync (the card is
detached, the port is gone, or the descriptor is in error, which ERTS
reports as readiness and the next sync turns into an error number), a
broken ring and a failed arm end the medium alike. The driver then
ends as [Ending](#the-driver) sets out for every driver: held to a
second from its start with its link told `down`, and its link started
again by the interfaces supervisor, whose intensity a link ending at
that pace never exhausts. The new driver registers the port again; a
switch port's slots and buffers start clean, and the new registration
resets a card's ring.

A failed registration is the medium ending too, not a refusal, because
a transport whose `init` fails is not held and is retried at once
([Ending](#the-driver)). `init` answers `{ok, Info, T}` with the link
`down` and the medium failed, and sends itself `{erx_netmap, failed,
{Step, Reason}}`. A missing card, `/dev/netmap` without permission, a
port another process holds (`ebusy`) or a predecessor's registration
that ERTS has not yet closed thus restarts the link at most once a
second for as long as it lasts, and fails neither the link's start nor
the stack's. A switch going away is not an event this transport sees:
the switch exists while any port is on it, this one included.

The handle closes in one place, the stop callback of `enif_select`,
which unmaps the region and closes the descriptor once ERTS's poll set
lets go of it. Two things request that stop: the owner's monitor, when
the driver ends however it ends, and the resource's destructor. Neither
leaves a caller behind, since only the owner may call and the
destructor runs only when no process holds the handle, so the NIF has
no close call and no closed state.

**Refusals at `init`.** Configuration and build errors refuse the start
with `{error, Reason}`, as the pipe's do, since restarting cannot fix
them: the keys of the table above, `{netmap, unavailable}` when the NIF
library is absent, `{netmap, {api, Kernel, Built}}` when the kernel
answers the registration with an API version other than the NIF's
headers, and `{mtu, N}` when the port's buffers cannot hold the MTU and
the Ethernet header.

**Building.** `make -C c_src` builds `priv/erx_netmap_nif.so` beside the
tap transport's NIF and the per-byte primitives' NIF library when the host's
compiler finds `<net/netmap.h>`: FreeBSD has it in its base system, and
Linux once netmap's headers are installed or `NETMAP_INCLUDE` names
them. Elsewhere, macOS included, the make prints one line saying the
transport is not built, and builds the rest. The headers fix the API
version the NIF requests. The NIF does not link `libnetmap`, whose
`nmport_open` adds a port-name syntax of options, extra memory and ring
suffixes this transport does not use; the raw `NIOCCTRL` request is the
kernel's own interface on both systems. It is a library of its own, so
that the per-byte primitives, which build everywhere, do not depend on
netmap. `erx_netmap_nif`'s `on_load` answers `ok` when its library is
missing and every call then answers `{error, unavailable}`, so a host
without netmap still loads the application and refuses only an
interface that names this transport. The ERTS headers come from the
`erl` that runs the node (`code:root_dir()`'s `usr/include`).
`erx_netmap_ring.c` includes no netmap header and works on the plain
values the NIF reads, such as a slot's chain flag as a boolean, so its
tests and fuzz target run on every host, macOS included. Only
`erx_netmap_nif.c` includes `<net/netmap.h>` and reads or writes the
mapping, with every offset taken from a plan of the core's
([Build checks](#build-checks)).

**Why a NIF, and why a copy.** A port program would keep C out of the
node, but it relays every frame through a pipe, a copy in and a copy
out with system calls on both sides, which are the costs netmap exists
to remove and which the comparison would then measure instead of the
stack; and ERTS delivers a port's data as fast as the program reads
it, so its frames would reach the driver's mailbox with no credit ahead
of them. The NIF keeps to the rule that C does only per-byte work and
the per-frame work that rides on it, copying bytes, cutting runs and
checking lengths and indices as the device NIF does, while every
decision about a frame stays in Erlang. A bug in it takes down the node, which outside erXos
is the whole stack, so its C is small and its decisions are in a pure
core under unit tests, a fuzz target and the sanitizers.

Receive copies rather than lending slots to binaries. The stack keeps
sub-binaries of received frames in reassembly queues and receive
buffers as long as a peer keeps data out of order, and a netmap ring
returns its slots in order, so one held 60-byte segment would hold
every slot behind it and stop the interface's receive for all clients.
Swapping a held slot's buffer for a spare avoids the stall, but needs a
pool of spares, a destructor that returns them from any thread, and a
copy anyway once the pool is empty: three new rules where the copy has
none. A 1,514-byte copy is expected to be a small part of the 12.3 us
a full-size frame may take at 1 Gb/s
([Where C is used](#where-c-is-used-and-what-is-measured)), an estimate
that measurement 2 replaces with a measured share. Transmit copies too:
`NS_INDIRECT`, a switch reading the frame from the process's memory,
exists only on switch ports and needs the frame kept alive until the
sync, which `erx_net_driver`'s contract does not give a transport.

**Tests.** Each is paired with a seeded fault that it must catch.

* *The core, on every host.* C unit tests of `erx_netmap_ring` run under
  `make check`. Layout: an honest layout passes; a ring past the end of
  the mapping, a buffer offset before it, an index whose product with
  the buffer size overflows, a slot count of 1 and a buffer smaller than
  the MTU and header are refused. Receive: an honest ring; a `tail` at
  the slot count and a length one past the buffer size break the ring;
  lengths of 13 and of the MTU and header plus one are dropped
  `malformed` and `too_long`; a chain of three slots split across two
  calls is dropped whole; a batch stops at 64 KiB and at 256 slots with
  `more`. Transmit: room up to `tail` and no further; a full ring; a run
  that fits in part, planned for the slots there are; sizes of 13 and of
  the MTU and header plus one, dropped as on receive.
  *Seeded failures:* the receive length check removed, the `tail` check
  written `<=`, and the transmit size check removed must each fail
  their case.
* *The fuzz target.* `tools/fuzz/netmap_ring_fuzz.c` drives the core
  over a fake mapping built from its input: the layout fields, the
  slots, a sequence of `tail` values across calls, and the sizes of
  frames to send. It checks that every planned copy, received or sent,
  lies inside one buffer and inside the mapping, that `head` moves only
  towards `tail`, that a receive plans at most 64 KiB and one frame and
  at most 256 slots, and that no slot of a chain is ever planned as a
  frame. It runs under the sanitizers, as every C target does. *Seeded
  failures:* the receive buffer bound removed, the transmit size bound
  removed, and a chain flag that each call starts clear must each fail
  within the target's budget.
* *The transport over a fake ring.* In tests only, the `nif` key of the
  configuration names a module of the same functions over a ring held
  in Erlang, which sends the select messages itself and, as the NIF
  is, is `badarg` on a `send/2` whose frame has more than 64 binaries.
  A property test over random orders of arrivals, sends of frames of one
  or many binaries and of runs, and wakes checks that at most one receive wake is ever in
  flight, that a frame in the fake ring always has a wake on its way,
  that every transmit before a flush leaves in that one sync, and that
  `writable` comes only from the write arm's message. Driver tests
  check that each error the fake can answer (a failed sync from each
  call, a failed arm from `recv/1` and from a full `send/2`, a broken
  ring, a failed registration) ends the driver with `{shutdown,
  {netmap, Reason}}` no sooner than a second after its start; that many
  queued transmits meeting one failure send one `failed`; and that each
  refusal of `init` is the one listed. *Seeded failures:* a transport
  that sends itself `more` after `armed` must break the one-wake
  property; one that never arms after emptying the ring must leave a
  frame with no wake; one that reports `writable` at a flush must fail
  the `writable` check; one that answers a run partly taken as taken
  whole must lose the frames the test counts; one that reads `{error, arm}` as `armed` must
  leave the driver running; and one that refuses `init` on a failed
  registration must end sooner than a second.
* *The FreeBSD switch run.* A host test, run on the FreeBSD test host,
  skipped elsewhere with its reason stated, never counted as passed.
  Two drivers on `vale0` exchange frames of 60, 1,514 and the MTU's
  largest size, each sent as one binary and as headers and a payload of
  several binaries, unchanged in both directions. The stack takes jail
  `erxpeer0`'s ARP and ping over the switch and runs a UDP echo and a
  TCP transfer with it. A second registration of the same port is
  refused with `ebusy`. A killed driver's link is started again,
  re-registers the port and answers ping again. An MTU over the buffer
  size is refused at `init`. A stream of single frames at random gaps,
  about 100,000 empty-ring arms in all, gets every frame through within
  100 ms, which checks the lost-wakeup argument against FreeBSD's
  `netmap_poll` and ERTS's kqueue. *Seeded failures:* a NIF that sets
  each slot's length one short must fail the 1,514-byte case, and one
  that never arms must stall the stream. The same run on a Linux host
  with netmap's module, once one joins the test hosts, checks the NIF's
  `ioctl` numbers and `epoll` against netmap's poll handler there.

**Measurements.** The numbers name the host, the operating system and
kernel, OTP, the compiler and flags, the frame sizes and the baseline,
as every network number does; raw data goes in `~/erxos-history`, and
the record in a research report that cites it. The per-byte primitives
are the same C on every host
([Two places, four seams](#two-places-four-seams)), so the stack's
checksums cost what they cost on erXos. Two measurements, of what the
transport itself costs, are owed before it lands:

1. *The switch's ceiling.* `pkt-gen` sending to `pkt-gen` on `vale0`,
   60- and 1,514-byte frames, packets per second and Gb/s, one core
   each.
2. *The transport alone.* `pkt-gen` sending to a driver whose
   stand-in interface takes and counts every batch, and the driver
   sending prebuilt frames as fast as its credit lets it to `pkt-gen`,
   once as single binaries, once as headers and a payload, and once as
   runs. Same sizes, with the node's CPU time from `getrusage` and a
   profile that gives the share of the copies, the cut, the binaries and
   the syncs.

The comparisons are owed after it lands, and each decides only where
the stack's own time goes:

3. TCP bulk transfer, one flow each way, and request-response, between
   `erx_net` and FreeBSD's stack in `erxpeer0` over the switch, with the
   CPU time of the node and of the host's kernel. The jail's `epair` is
   in netmap's emulated mode, which copies through mbufs, so `pkt-gen`
   to the jail gives that path's own ceiling first.
4. The same loads between lwIP over netmap and the jail, and between
   two jails on the switch, as the two baselines. lwIP has no netmap
   port of its own, so it runs over a small `netif` for lwIP's UNIX
   port written against `NIOCCTRL` as this NIF is, kept outside erXos's
   tree and fetched at a pinned commit like the other oracle tools; both
   sides then use the same registration and sync pattern.
5. Minimum-size UDP frames from `pkt-gen` to an `erx_net` socket:
   receive packets per second and drops by reason, which is the
   interface process's ceiling over a medium that costs almost nothing.

Over a tap on the FreeBSD test host the limit was the stack's per-segment work, not the
medium ([design-network-fastpath.md](design-network-fastpath.md#what-was-measured)),
so this transport alone is not expected to raise TCP throughput much;
with the fast path's runs and merge it is where the stack is compared
with lwIP over the same switch. It gives the comparison the medium the
other stacks use, at a measured and small cost, and the packet rate of
minimum-size frames.

**Residuals of the transport.**

* A process that can open `/dev/netmap` can read and write the buffers
  of every port in a shared memory region, a card's included. This is
  netmap's own model. The transport's checks keep such a process from
  corrupting the node's memory, but not from altering frames.
* A netmap that reported a descriptor readable while its ring held
  neither frames nor an error would make the driver arm, wake and find
  nothing, again and again. Each round is preemptible and bounded. That
  behaviour has not been seen, and the switch run watches the driver's
  wakes per frame.
* Frames past the interface's receive credit are copied before the
  driver drops them as `no_room`. A driver that told the transport to
  leave them in the ring, where the switch or the card drops them for
  nothing, would need the receive credit's state across the
  transport's callbacks. That change waits for the flood numbers
  ([todo-performance.md](todo-performance.md)).

**Open decision.** *A second jail on the switch,* for the
FreeBSD-to-FreeBSD baseline of measurement 4. It changes the test host's setup,
which puts only `erxpeer0`'s `epair` on `vale0`, and so needs allowing.
Recommended: allow it; it is the one baseline that shows what
the switch and the emulated mode cost a kernel stack, apart from any
user-mode stack.

### The interface core

`erx_net_if_core` is the interface process's step. It holds the
sub-cores of the interface's state ([One owner, one step](#one-owner-one-step)):
`erx_arp` and `erx_nd6` over `erx_lltable`, `erx_nd6_dad`,
`erx_nd6_rtr`, the reassembly tables, the syncache, the ICMP and RST
limiters of `erx_net_bandlim`, the ingress bucket, its configuration
copy and its view, its generator and its counters, and dispatches each
event to the sub-core it belongs to.

```erlang
new(#{name := term(), link := erx_net_driver:link_info(),
      gen := erx_net_rand:gen(), config := map()}) -> core().
step(event(), core(), #{now := integer()}) -> {core(), [action()]}.
view(core()) -> erx_net_input:view().        % without demux, which the loop adds
next_deadline(core()) -> integer() | infinity.

-type event() ::
      start                                           % the first step: its rows, its announcements
    | {local, erx_net_input:pending()}               % classify/2 answered local
    | {reinject, erx_net_input:key(), [erx_tcp:segment()]}
    | {resolve | reset, NextHop :: term(), Src :: term(), [erx_net_frame:packet()]}
    | charge_rst
    | {hint, NextHop :: term()}
    | {config, Gen :: non_neg_integer(), erx_net_frame:snapshot()}
    | {link, up | down}
    | {dhcp, erx_dhcp4_core:action()}                % from the interface's erx_dhcp4
    | {ifid, Ref :: reference(), {ok, binary()} | unavailable}
    | {accept_refused, Conn :: term(), erx_tcp:segment()}
    | {admin, Request :: term(), From :: term()}     % netadmin's requests
    | {drop, Reason :: atom()}                       % the loop dropped a frame: counted
    | {expired, Now :: integer()}.

-type action() ::
      {transmit, [erx_net_frame:frame()]}            % to its driver
    | {hand, pid(), erx_net_credit:credit(), Units :: pos_integer(), Msg :: term()}
    | {input, erx_net_input:input()}                 % classify again: a reassembled datagram
    | {publish, Rows :: map()}                       % its rows of the three configuration tables
    | {neigh, publish, Ip :: binary(), LinkAddr :: binary(), fresh | stale}
    | {neigh, unpublish, Ip :: binary()}
    | {dhcp, {reply, Msg :: term()} | {link, up | down}}
    | {ifid_request, Ref :: reference(), Message :: binary()}
    | {accept, erx_tcp_syncache:listener(), Conn :: term(),
       erx_tcp_syncache:handshake(), erx_tcp:segment(), erx_net_rand:gen()}
    | {reply, From :: term(), Reply :: term()}.
```

The context is the time alone, in microseconds; the sub-cores that keep
milliseconds get it divided. The step of a `local` event does what
[Receiving](#receiving) gives the interface: `charge/2` decides whether
the frame spends a token of the bucket, `erx_net_input:verify/1` checks
it, a failed check gives the token back, and the verified item goes to
its sub-core, all inside the one step, so the bucket has no state
outside the core and nothing to give back after a raise. `hand` reaches
another stack process through the pid and credit of its published row,
as the ICMPv6 error of an unresolved neighbour reaches the loopback
interface. `publish` carries the complete set of the interface's rows in
`erx_net_ifs`, `erx_net_addrs` and `erx_net_routes` whenever one of them
changes.

**The loop.** `erx_net_if` takes one message at a time:

1. Before anything else it reads the configuration generation, and when
   it differs from the core's, steps `{config, Gen, Snapshot}` from
   `erx_net_tables:configuration/0`.
2. A batch `{frames, Driver, Frames}` takes its units from the receive
   credit, and so does every further batch from the driver already in
   the mailbox, up to a link notice, which is stepped after them
   ([Processes and batching](design-network-fastpath.md#processes-and-batching));
   a `{loop, Frames}` takes its units from the sender credit. Each
   frame in turn is classified against `view/1` with the `demux` lookup
   added. An `owned` frame reserves a unit of each destination's credit
   and is verified, its item kept for each destination that took it, or
   its units released if it fails. A `local` frame is stepped at once,
   and every `{input, Input}` action it returns is classified before the
   next frame. A `drop` is counted. At the end of the batches taken
   together each destination gets one message of its items, its units
   already reserved.
3. Any other handed message takes its units from the sender credit and
   is stepped. `hint`, `link`, the `erx_dhcp4` messages and the key
   facet's answer carry no credit: a hint is at most one in flight per
   published row, a link notice took a unit of the receive credit at the
   driver, and the others come from processes of the interface's own
   link supervisor or from its own requests, one per step.
4. A clock hint steps `{expired, Now}`.

After each step the loop performs the actions in order: it writes
`publish` as new and changed rows first, deleted rows last, and then
increments the generation; it sends an `ifid_request` to the key facet
of [IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration),
and steps `{ifid, Ref, unavailable}` itself when the network domain
holds none, as on a host. Then it arms the clock at
`next_deadline/1`. A step that raises is handled as
[What fails and what survives](#what-fails-and-what-survives) says.

**A connection from the syncache.** For `accept`, the loop reserves one
unit of the listener's accept credit. Refused, it steps
`{accept_refused, Conn, Segment}`, and the core answers with a RST under
its limit ([Connection setup](#connection-setup)). Granted, the loop
makes the connection's receive credit, spawns the connection with
`proc_lib:spawn/3`, so the interface never waits on it, and inserts the
four-tuple through `erx_net_bind` with the new pid and credit before it
takes the next frame. The connection's first message is the interface's
verdict on that insertion: `go`, or `abandon` when the key was already
held, on which it ends without sending anything and the loop releases
the accept unit. Here the interface, not the receiver, makes the
receiver's counter, so that the entry exists before the connection runs.

### Credits

`erx_net_credit` is the one module that hands packets between stack
processes, over one `atomics` counter per receiver
([Credited queues](#credited-queues)):

```erlang
-opaque credit() :: {atomics:atomics_ref(), Limit :: pos_integer()}.

new(Limit :: pos_integer()) -> credit().
hand(pid(), credit(), Units :: pos_integer(), Msg :: term()) -> ok | full.
reserve(credit(), Units :: pos_integer()) -> ok | full.
send(pid(), Msg :: term()) -> ok.          % a message whose units are reserved
release(credit(), Units :: pos_integer()) -> ok.
take(credit(), Units :: pos_integer()) -> ok.
free(credit()) -> non_neg_integer().
```

`reserve/2` adds the units with `atomics:add_get/3` and, past the
limit, subtracts them again and answers `full`. `hand/4` is `reserve/2`
followed by `send/2`. `release/2` returns units a sender reserved and
did not send; `take/2` is the receiver's, for each message or frame it
takes; `free/1` is the room left, which a connection's loop reads into
its step's context. The limit is part of the value, fixed when the
counter is made, so a sender never reads it from anywhere else, and a
counter can never go below zero, since every unit is added before its
message is sent. Each credit's unit and limit:

| Credit | Made by | Unit |
| --- | --- | --- |
| a driver's transmit credit | the driver, at `init` | a frame |
| an interface's receive credit | the interface | a frame of a batch, or a link notice |
| an interface's sender credit | the interface | a handed message |
| a connection's or datagram socket's credit | the socket, or the interface for a connection it starts | a segment, datagram or ICMP report; a merged segment takes one for each segment it holds |
| a listener's accept credit | the listener | a connection, its limit the backlog |

The limits are keys of the `erx_net` application's environment, whose
defaults the flood measurements of plan.md's network gates settle, as
they settle the ingress bucket's.

### The clock

`erx_net_clock` is the stack's one source of what differs from one run
to the next: the time, the timers and the random keys. Every process of
`erx_net` reads the time, arms its one timer and draws entropy through
it, and through nothing else:

```erlang
now() -> integer().                       % microseconds
arm(Deadline :: integer()) -> ok.         % the caller gets {erx_net_clock, hint} at or after Deadline
entropy(N :: pos_integer()) -> binary().  % N bytes for a key; raises when the source fails
```

The clock is chosen once, from the application's `clock` key, before any
process starts. `monotonic`, the default and the only value the network
domain's configuration sets, is `erlang:monotonic_time(microsecond)`,
`erlang:send_after/4` with `{abs, true}` at the deadline rounded up to
the millisecond, and `erx_bytes:entropy/1`. `{virtual, Clock}` is a
test's clock process, served by the module `erx_net_vclock`, which is
test code in `erx_net`'s `test/` and is packed into no image and no
release; where it is absent, the application refuses to start with
`{error, {seam, clock, erx_net_vclock}}`, so a production build cannot
run on a virtual clock or a seeded generator. Under it, `now/0` reads
the current time from an `atomics` counter the clock shares; `arm/1`
tells the clock the caller and deadline, and the clock keeps one
deadline per caller, the earliest it was given, until it sends that
caller's hint; `entropy/1` asks the clock for the next bytes of an
`erx_net_rand` generator keyed by the run's seed. The clock moves only
when the test advances it, setting the new time first and then sending a
hint to every caller whose deadline it reached, in order of deadline and,
for equal deadlines, of arming.

A virtual clock is this simple because a hint is only a hint
([Deadlines, not timers](#deadlines-not-timers)): the clock never
cancels anything, and a hint for a deadline that has since moved finds
nothing due. Every timeout of the stack is a deadline in some owner's
state, a request's `Timeout` included, which the socket enforces, so
nothing in the stack waits on a timer the virtual clock does not see; a
local call between stack processes waits with a monitor and the timeout
`infinity`. A build check keeps it so ([Build checks](#build-checks)).
Under the virtual clock, `erx_net_script` drives the whole stack through
the pipe driver's `process` end: it advances the clock only when the
stack is idle, every process of the `erx_net` tree, every socket and the
pipe waiting in `receive` with an empty queue, so a 2MSL wait or a
keepalive's two hours take no time. Each such run has a node of its own
with one scheduler (`+S 1`), and every supervisor starts its children
one at a time, so the processes run, and draw their keys, in the same
order every time: a run's frames on the wire are a function of its
script and its seed. Runs against real peers keep the monotonic clock.

### The grant's contract

What the stack's modules rely on from a grant is fixed here, so neither
the runtime seam nor the facet machinery changes them:

* A grant is an `erx_net_grant` process, minted by `erx_net:mint_grant(Grantee,
  Connection, Limits, Exports)`, the one function the network service's
  introduction of a client calls ([The grant](#the-grant)), which starts
  it through the runtime's `start_grant/2`, exported to its grantee and
  ending with its connection. It holds the limits of
  [The grant](#the-grant) and the account of
  [Sockets act for one domain](#sockets-act-for-one-domain), which a
  pure core, `erx_net_grant_core`, decides over.
* Every message from outside the stack to a grant or a socket passes one
  admission path before any step sees it:

  ```erlang
  %% A message to a grant.
  erx_net_admit:request(Msg :: term(), Grantee :: local | pos_integer()) ->
      {ok, Request :: term(), From :: gen_server:from()}
    | {refused, shape, From :: gen_server:from()}
    | unknown.
  %% A message to a socket of kind Kind whose socket process is SockProc.
  erx_net_admit:request(Kind :: tcp | udp | icmp, Grantee :: local | pos_integer(),
                        SockProc :: pid() | none, Msg :: term()) ->
      {ok, Body :: term()} | {refused, shape} | unknown.
  ```

  A socket takes only its own kind's requests: a datagram socket
  `{send_to, Ip, Port, Data}`, `{send, Data}`, `{connect, Ip, Port}`,
  `sockname` and `close`; an echo socket `{echo_send, Ip, Seq, Ttl,
  Data}` and `close`; a connection those of
  [The socket process](#the-socket-process); and every kind `{credit,
  Bytes}`. A request of another kind is refused for its shape.

  A message wrapped as `{erx_origin, D, Inner}` comes from domain `D`; a
  message without an envelope comes from the receiver's own domain,
  `local` ([design-domains.md](design-domains.md#facets)). The origin
  must be the grantee, and a grant's message must be a call,
  `{'$gen_call', From, Request}`, whose reply goes to the grantee's domain:
  `From` is `{Pid, [alias | Alias]}`, and both `Pid` and `Alias` carry the
  grantee's domain id
  ([design-domains.md](design-domains.md#domain-ids-pids-and-references)),
  since `gen:reply/2` sends to the alias rather than to the pid, as a
  facet requires of its caller
  ([design-domains.md](design-domains.md#facets)); a message without an
  envelope needs only a pid of the grant's node; a
  socket's must name that socket's own socket process as its sender
  ([Sockets act for one domain](#sockets-act-for-one-domain)). A message
  that fails either is `unknown`: dropped and counted, and answered to no
  one, since its reply would go to a party outside the grantee's domain
  or to no socket process of the socket. `Request` must then be a request
  of `abi/services/net.txt`, within the bounds the schema declares for
  each argument ([Message sizes](#message-sizes)); one that is not is
  refused for its shape, answered `{error, badarg}` and counted, as a
  facet refuses ([design-domains.md](design-domains.md#facets)). The
  admitted request comes back with its caller, and the caller is the
  owner of what the request opens: no request names an owner of its own,
  so no request can make a socket serve a process of another domain. The
  stack's own calls of a grant (a connection's reservation and release of
  its buffers, and the grant's counts) are admitted only without an
  envelope and from a process of the grant's node. The mint has the same
  path, `erx_net_admit:mint/2`, which takes only `{erx_facet_mint, Tag,
  net, Grantee, Principal, Limits}` in the system domain's envelope
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
  and refuses and counts one whose `Grantee` is the system domain's id
  (**The system domain never holds the grant**, in [The grant](#the-grant)).
  `erx_net_admit` is generated from the schema into the app's build
  output, the one generated module `erx_net` needs; an app taken out of
  the tree carries that output with it. Until the schema generator
  exists it is hand-written with the generated module's exact signature
  ([Decisions](#decisions), 10). The grant, under `erx_facet`, reaches
  the same check through the facet's behaviour, and under
  `erx_net_local`'s loop through a call before each callback. Two
  bounds apply, and neither drops a request a correct client sends. The
  runtime's request limit on the receiving process, which `serve/1` sets
  to the grant's `max_request`, the schema's largest request, drops a
  larger message before it is queued. The requests in flight are the
  admission's: the grant's are bounded by its facet's limit in flight,
  past which requests wait in the facet's queue and then in the
  grantee's lane ([design-domains.md](design-domains.md#facets)), and a
  socket's by the socket protocol's 64, which its socket process never
  exceeds ([Requests in flight](#requests-in-flight)).
* A client finds its grant through `erx_net_client`'s `grant` key and
  nothing else: `erx:cap(net)` on erXos, with the origin its messages
  carry ([Two places, four seams](#two-places-four-seams)).
* A socket speaks to its socket process, and to nothing else, in the
  socket protocol of [The socket process](#the-socket-process).

With the local runtime, `erx_net` mints its node's grant with the
grantee `local` at start, and a test harness mints any others the same way. No message
there carries an envelope, so every request from a process of the node
passes the origin check, and the grant's limits, account and refusals
are exactly those of the network domain. Outside erXos there is
therefore no grant that admits by caller: the variant would only
reproduce what `local` already gives.

### Running on a development host

The host harness starts `erx_net` on stock OTP 29.1.2 with its
`interfaces` key naming each interface's transport and configuration
(`{erx_net_pipe, #{far := far(), lladdr := Addr}}`, static addresses or
DHCP), as the network domain's configuration names `erx_virtio_net`,
its `clock` key, and `runtime` set to `erx_net_local`; `erx_net_client`'s
`grant` key is `{erx_net, local_grant, []}`.

Stock's `inet` accepts only `inet` and `socket` as backends
(`inet.erl:3297-3300`), so `{inet_backend, erx}` fails there with
`function_clause`. Host tests therefore open sockets by calling the
backend directly, `erx_gen_tcp:connect/4`, `erx_gen_tcp:listen/2` and
`erx_gen_udp:open/2` with `gen_tcp`'s and `gen_udp`'s arguments. Each
returns `{'$inet', erx_gen_tcp, Pid}` or `{'$inet', erx_gen_udp, Pid}`,
on which every later `gen_tcp`, `gen_udp` and `inet` call dispatches to
the backend as on erXos. On erXos the OTP edit that adds `erx` to
`inet_backend` and makes it the default ([The backend](#the-backend))
is all that changes: the calls into `erx_gen_tcp` are the same.

## Modules and provenance

### Modules

The stack is the application `erx_net`, in `erlang/apps/erx_net/`. Pure
modules are marked P; process modules E.

| Module | FreeBSD source (sys/netinet, sys/netinet6, sys/net) | Role | |
| --- | --- | --- | --- |
| `erx_net_eth` | `if_ethersubr.c` (`ether_input` checks) | Ethernet II codec | P |
| `erx_arp_wire`, `erx_arp` | `if_ether.c` | ARP codec; neighbour state machine | P |
| `erx_lltable` | `if_llatbl.c` | the neighbour table of ARP and neighbour discovery | P |
| `erx_ip4_wire`, `erx_ip4` | `ip.h`, `ip_input.c`, `ip_output.c`, `ip_options.c`, `ip_id.c` | IPv4 codec; input and output decisions | P |
| `erx_ip_reass` | `ip_reass.c`, `frag6.c` | the reassembly table both families share: caps, lifetimes, placing and completing fragments | P |
| `erx_ip4_reass` | `ip_reass.c` | IPv4 reassembly | P |
| `erx_icmp4_wire`, `erx_icmp4` | `ip_icmp.c` | ICMP codec and decisions | P |
| `erx_net_bandlim` | `badport_bandlim` and `icmplim_new_jitter` in `ip_icmp.c`; `icmp6_ratelimit` and `icmp6lim_new_jitter` in `icmp6.c` | the rate limits on ICMP and ICMPv6 answers and RSTs, with their jitter | P |
| `erx_ip6_wire`, `erx_ip6` | `ip6_input.c`, `ip6_output.c`, `dest6.c`, `route6.c`, `scope6.c`, `ip6_id.c`, the fragment-header checks of `frag6.c` | IPv6 codec with the extension-header walk; decisions | P |
| `erx_ip6_reass` | `frag6.c` | IPv6 reassembly | P |
| `erx_icmp6_wire`, `erx_icmp6` | `icmp6.c`, the option parsers of `nd6.c` and the option lengths `nd6_rtr.c` checks | ICMPv6 and neighbour-discovery codec; decisions | P |
| `erx_nd6`, `erx_nd6_dad`, `erx_nd6_rtr` | `nd6.c`, `nd6_nbr.c`, `in6.c`, `nd6_rtr.c`, `in6_ifattach.c` | neighbour cache; DAD; routers, prefixes, autoconfiguration | P |
| `erx_in6_src` | `in6_src.c` | source address selection | P |
| `erx_net_addr` | `in.c`, `in6.c` | address checks | P |
| `erx_net_route` | none | longest-prefix lookup | P |
| `erx_net_sum` | none: RFC 1071's arithmetic | one's-complement addition and subtraction of sums, `add/2` among them, and `span/4`, the sum of a span of a packet from the packet's sum ([Checksums in the copy](#checksums-in-the-copy)) | P |
| `erx_udp_wire`, `erx_udp` | `udp_usrreq.c`, `udp6_usrreq.c` | UDP codec, with the checksum and length rules of each IP version; decisions | P |
| `erx_tcp_wire` | `tcp.h`, the checksum and data-offset checks of `tcp_input_with_port` (`tcp_input.c:640-756`), `tcp_dooptions` (`tcp_input.c:3501`), `tcp_addoptions` (`tcp_output.c:1794`) | TCP codec, checksum first, and options | P |
| `erx_tcp_seq` | `tcp_seq.h` | lifting and wire conversion | P |
| `erx_tcp` | `tcp_input_with_port` (`tcp_input.c:594`), per connection | the step: dispatch and output | P |
| `erx_tcp_input` | `tcp_do_segment` (`tcp_input.c:1511`) | the segment pipeline | P |
| `erx_tcp_output` | `tcp_output.c` | output | P |
| `erx_tcp_timer` | `tcp_timer.c`, `tcp_timer.h` | expirations | P |
| `erx_tcp_user` | `tcp_usrreq.c`, `tcp_drop` (`tcp_subr.c:2393`), `tcp_close` (`:2532`), `tcp_newtcpcb` (`:2233`) | user requests | P |
| `erx_tcp_sndbuf` | none | the send buffer: a queue of the owner's binaries, read as sub-binaries | P |
| `erx_tcp_rtt` | `tcp_xmit_timer` (`tcp_input.c:3642`), the timeout of `tcp_timer_rexmt` (`tcp_timer.c:631-635`), `TCP_REXMTVAL`, the estimator fields of `tcp_newtcpcb` | RFC 6298 estimator and the backed-off timeout | P |
| `erx_tcp_mss` | `tcp_mss` (`tcp_input.c:3899`), `tcp_mss_update`, `tcp_mssopt`, `tcp_maxseg` (`tcp_subr.c:3780`), `tcp_compute_initwnd` | MSS and initial window | P |
| `erx_tcp_sendlog` | none: written from RFC 6675 sections 4 and 5, as `tcp_sack.c` is not read | the send log and RFC 6675 scoreboard | P |
| `erx_tcp_sack` | none: written from RFC 2018 and RFC 2883, since `tcp_sack.c` carries an advertising clause | SACK and D-SACK blocks | P |
| `erx_tcp_reass` | `tcp_reass.c` | out-of-order queue | P |
| `erx_tcp_loss`, `erx_tcp_loss_dupack` | loss parts of `tcp_input.c` and `tcp_timer_rexmt` in `tcp_timer.c`; RFC 6675, RFC 6937, RFC 3042 and RFC 6582 for those of `tcp_sack.c`, which is not read | behaviour; default loss detection | P |
| `erx_tcp_cc`, `erx_tcp_cc_newreno`, `erx_tcp_cc_cubic` | `cc/cc.h`, `cc/cc.c`, `cc_newreno.c`, `cc_cubic.c`, the `cc_*` callers in `tcp_input.c` | behaviour; NewReno; CUBIC | P |
| `erx_tcp_ecn` | `tcp_ecn.c` | ECN | P |
| `erx_tcp_isn` | `tcp_new_isn`, `tcp_new_ts_offset`, `tcp_keyed_hash` (`tcp_subr.c`) | initial sequence numbers, timestamp offsets | P |
| `erx_tcp_syncache` | `tcp_syncache.c` | half-open table, cookies | P |
| `erx_tcp_icmp` | `tcp_ctlinput_with_port`, `tcp6_ctlinput_with_port`, `tcp_notify`, `tcp_mtudisc`, `tcp_drop_syn_sent` (`tcp_subr.c`) | ICMP reports for TCP | P |
| `erx_tcp_timewait` | `tcp_twstart`, `tcp_twcheck`, `tcp_eff_msl` (`tcp_timewait.c`) | TIME-WAIT | P |
| `erx_tcp_hostcache` | `tcp_hostcache.c` | per-destination path values (an extension, [Scope](#scope)) | P |
| `erx_mcast` | `in_mcast.c`, `igmp.c`, `in6_mcast.c`, `mld6.c` | group membership, IGMPv3 and MLDv2 (an extension) | P |
| `erx_net_bind` | `in_pcb.c` (`in_pcbbind`, `:716`; `in_pcb_lport_dest`, `:756`; `in_pcbbind_avail`, `:912`; `in_pcbbind_setup`, `:1011`), `in6_pcb.c` | port choice, reuse rules, the claim funnel | P and the funnel |
| `erx_net_input` | `ether_input`, `ether_demux`, `ip_input`, `ip6_input`, the pcb lookups of `tcp_input_with_port`, `udp_input`, `tcp_ctlinput` and `udp_common_ctlinput` | classify one frame against the interface's view; verify it once it holds room | P |
| `erx_net_frame` | `in_pcbladdr`, the header-building and next-hop parts of `ip_output`, `ip6_output`, `ether_output`, `arpresolve_addr` | a destination's path from the configuration; packets; frames or a hand-over to the interface | P |
| `erx_net_rand` | none; the role of `arc4random` | the keyed random generator each owner holds | P |
| `erx_net_if_core` | composes the interface's sub-cores | the interface's step | P |
| `erx_dhcp4_wire`, `erx_dhcp4_core` | `parse_options`, `parse_option_buffer`, `check_classless_option`, `res_hnok`, `check_search`, `option_as_string` of `sbin/dhclient`; RFC 2131, RFC 2132, RFC 3396, RFC 3442 | DHCP message codec; DHCP client state machine | P |
| `erx_net_grant_core` | none | the grant's limits, account and buffer reservations | P |
| `erx_net_credit` | none | credited hand-over | funnel |
| `erx_net_tx` | none | the sockets' transmit edge: packets to the driver against its credit, or to the interface to resolve | E |
| `erx_net_clock` | none | the time, the one timer and the entropy of every process | funnel |
| `erx_net_admit` | generated from `abi/services/net.txt`; hand-written with the same signature until the generator exists | the admission path of grants and sockets | generated |
| `erx_net_runtime` | none | the runtime seam's behaviour | behaviour |
| `erx_net_driver` | none | the driver process over its transport | E |
| `erx_net_loop`, `erx_net_pipe` | none | the driver's portable transports | E |
| `erx_virtio_net`, `erx_net_erxos` (in `erxos/`) | none | erXos's transport and runtime | seam |
| `erx_bytes`, `erx_net_local` (in `portable/`) | none | the portable per-byte primitives and runtime | seam |
| `erx_net_bytes`, `erx_inet_csum`, `erx_siphash` (in `c_src/`, C17) | none | the per-byte primitives' C, linked into erXos's ERTS and built into the portable library | per-byte |
| `erx_tcp_cut`, `erx_tcp_merge` (in `c_src/`, C17) | the rules of `tcp_output`'s TSO handling and of `tcp_lro_rx_common` and `tcp_lro_condense` (`tcp_lro.c`) | the cut of a run into frames, linked by the transports' NIFs; the merge of received segments behind `erx_bytes:tcp_merge/1` ([design-network-fastpath.md](design-network-fastpath.md)) | per-byte |
| `erx_tcp_payload` | none | payloads as flat lists of binaries: length, part | P |
| `erx_tap`, `erx_tap_nif` (in `portable/`) | none | the tap transport and its NIF's loader ([The tap transport](#the-tap-transport)) | E |
| `erx_tap_nif.c` (in `c_src/`, C17) | none | the tap NIF: reads, `writev` and the cut's headers over the tap's descriptor | host NIF |
| `erx_netmap`, `erx_netmap_nif` (in `portable/`) | none | the netmap transport and its NIF's loader | E |
| `erx_netmap_nif.c`, `erx_netmap_ring.c` (in `c_src/`, C17) | none | the netmap NIF: its effects over the mapping, and the pure core that plans each call | host NIF |
| `erx_icmp_sock` | `raw_ip.c` (`rip_input`, `rip_send`), the parts `ping` uses | the ICMP echo socket | E |
| `erx_net_if`, `erx_tcp_conn`, `erx_tcp_listen`, `erx_udp_sock`, `erx_net_grant`, `erx_net_tables`, `erx_dhcp4`, `erx_epmd` | none | processes | E |

The packet-script runner `erx_net_script`, the virtual clock, the
impairment schedule `erx_net_impair` and the relay `erx_net_relay` are
test code in `erx_net`'s `test/`, beside the stack's unit tests, fuzz
targets and explorer, all run on stock OTP from the app directory alone
([The stack on a development host](#the-stack-on-a-development-host)).

The client side is the application `erx_net_client`, in
`erlang/apps/erx_net_client/`, which every erXos domain runs beside
`erx` and a node outside erXos runs beside `erx_net`: `erx_gen_tcp` and
`erx_gen_udp`, the socket backends, each the stubs `gen_tcp`, `gen_udp`
and `inet` call and the `gen_statem` of its socket process;
`erx_gen_icmp`, the echo socket's backend, which `ping` uses, whose
socket process is `erx_gen_udp`'s, started for the kind `icmp`, so one
`gen_statem` and one core serve every socket that carries whole
datagrams;
`erx_gen_tcp_core` and `erx_gen_udp_core`, the pure presentation step
each socket process runs; `erx_sock_admit`, the check of every message
the client side takes from the network domain, a socket's push or the
grant's answer; `erx_sock_out`, the socket process's one way to send to
its socket ([The socket process](#the-socket-process)); and `erx_inet`,
the one path to the grant, `call/1`, which the opener of a socket,
`inet:getifaddrs/0` and `ifconfig` use, and the resolver loader. It
depends on `kernel` and `stdlib` alone, and its calls into erXos are its
`grant` key's and the socket process's `expose/2`, both through
`erxos/erx_net_client_erxos`
([Two places, four seams](#two-places-four-seams)).

Rough size, from FreeBSD's line counts with what is not translated taken
out: the TCP core about 9,000 to 12,000 lines of Erlang, IP, neighbours
and UDP about 8,000 to 10,000, the processes, client side and port mapper
about 3,000. These are estimates for planning, not budgets.

### Provenance and notices

A module that translates FreeBSD code is a derived work of each FreeBSD
file it translates. Its header carries, after erXos's own notice, a line
`%% FreeBSD: PATH` for each such file, naming it by its path in the source
tree, followed by every copyright line and the licence text of that file
at the pinned commit, and its SPDX line names both licences, such as
`SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause`, so the packer
counts it as third-party for `NOTICES`
([design.md](design.md#licences-and-notices)). Its `-moduledoc` names the
FreeBSD files and the pinned commit; each function that translates a
FreeBSD function says so in its `-doc`, with the FreeBSD function's name,
so a reviewer compares the two side by side.

`erlang/apps/erx_net/NOTICE-freebsd` records the pinned commit and the
release the translation was read from, the SHA-256 of each one's source
archive, every change ported from between the two with its FreeBSD
commit, and for every module the FreeBSD files and functions it derives
from, as `kernel/NOTICE-fiasco` records the kernel's translation from
Fiasco. A change between the release and the pin is ported when the wire
or an interoperating peer can see it, or when it fixes a real bug;
anything else is left as it was read ([Decisions](#decisions), 9). The
notice and erXos's own licence notice are in the app directory, so the
app carries them wherever it goes (N12). The
FreeBSD source is a reference for readers, fetched by hand and not by the
build: the archive is
`https://github.com/freebsd/freebsd-src/archive/<commit>.tar.gz`, checked
against the SHA-256 in the notice. A
build check fails when a module's header names a FreeBSD file that the
notice file does not list for it, or the reverse.

Three files are never translated.
`netinet/in_cksum.c` carries the four-clause BSD licence with its
advertising clause (`in_cksum.c:17`); the Internet checksum is erXos's
own per-byte primitive. `netinet/tcp_sack.c` carries, besides the
Regents' notice, NRL's notice with an advertising clause, which erXos
does not take into its tree; the receiver's SACK blocks are written from
RFC 2018 and RFC 2883, and the sender's scoreboard and recovery from RFC
6675, each without reading it. RACK's
`tcp_stacks/tailq_hash.c` and `.h` carry no licence header; a RACK module
reads `rack.c` for its logic and builds its records on the send log.

A translation keeps FreeBSD's decision and drops its mechanism. A
reviewer checks each translated function for: the same branches on the
same conditions, in the same order where order is visible on the wire;
constants and defaults taken from FreeBSD by name; and a comment at each
place it departs, citing this document.

## Authority and admission

### Who holds the network device

Only the network domain holds a network device, by the system manifest
and its check ([design-system.md](design-system.md#the-manifest), rule
8). The driver is a process of the network domain, and the stack talks to
it as to any local process. No client domain reaches a driver, an
interface process or a shared table.

### The grant

A domain's use of the network is one grant: an `erx_net_grant` process
in the network domain, an instance of the `erx_facet` behaviour bound to
the domain. The network service makes it when the system domain
introduces the network domain to the client, as a storage service makes
its grants ([design-system.md](design-system.md#creating-a-domain)), and
the client's runtime installs it under the name `net`
([design-system.md](design-system.md#granting-a-running-domain)). Its
operations and their bounds are declared in the network service's
operation schema, `abi/services/net.txt`, from which the build generates
the client stubs, the admission path and the request validators
([design-domains.md](design-domains.md#authority)). A domain without the
grant gets `{error, eacces}` from every call that would need it, as
POSIX's `socket` answers a refused protocol.

**Its start and its end.** The mint starts a grant with the grantee's
id and the port of the network domain's connection to the grantee,
which the domain agent's `erx_connections:connection/1` answers once the
peer's entry is up. The grant monitors that port first, then exports
itself to the grantee with `send` alone, and only then does its start
return: the mint never answers with a grant its grantee cannot reach,
and a refused export is the start's refusal, which leaves no grant. The
grant ends with `{shutdown, connection_ended}` when the port ends. The
port lives exactly as long as the connection, and a port monitor is
local and matched by its reference, so no other process can forge the
end, as one can a `{nodedown, Node}` message, and it needs no node
monitor of the distribution. Because the monitor comes before the
export, the connection's end at any moment ends the grant, even when a
newer connection has replaced it by the time of the export, and the
grant's export goes with it
([design-domains.md](design-domains.md#exports), D13). A grant is never
restarted: the domain service grants a domain again only when either
domain restarts.

**The system domain never holds the grant.** The trusted base parses
no network traffic: no socket's stream, push or exit and no answer of
the grant enters the system domain, and whatever in it would need the
network runs in a service domain instead. The manifest's check refuses
a `net` facet granted to the system domain, and the mint refuses the
system domain's id as a grantee
([design-system.md](design-system.md#the-manifest), property 15). The
network utilities, `ifconfig`, `ping` and `host`, therefore run in a
session that holds `net`, root's session at the UART in a development
build, which holds every facet a session can hold
([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
and not in the system shell. So every client of the grant is a domain
whose loss of a message or whose stop harms only itself, and nothing in
the socket protocol has a case for the system domain's queue, which
drops a plain message past `system_queue` and ends the domain at any
other signal past it
([design-domains.md](design-domains.md#flow-control)).

The grant's limits come from the domain's specification within its
principal's policy:

| Limit | Meaning | Default |
| --- | --- | --- |
| `sockets` | sockets open at once, listeners and accepted connections included | 1,024 |
| `buffers` | bytes of send and receive buffer reserved across the grant's sockets; what a socket has pushed to its socket process is the client's own memory and does not count | 16 MiB |
| `time_wait` | connections in TIME-WAIT | 4,096 |
| `ports` | local ports the grant may bind explicitly; ports below 1,024 only when listed, as FreeBSD requires privilege for them (`ipport_reservedhigh`, `in_pcb.c:132`) | 1,024 to 65,535 |
| `listen` | whether the grant may listen, and on which of its ports | yes |
| `addresses` | local addresses the grant may bind | all |
| `share` | reductions per period, the facet's share | the policy's |
| `max_request` | the largest decoded request the grant and its sockets take; the runtime drops a larger one before it is queued | fixed, not a policy's: the schema's largest request, which the generator computes |

Configuring interfaces and reading every client's statistics is a second
facet, `netadmin`, granted to administrators. Reading the interfaces
needs only `net`, as FreeBSD's `ifconfig` shows them to any user:
`erx_net:interfaces/0` is the one read
path for an interface's state: each interface process answers for itself
with its name, link-layer address, MTU, link state, configuration
(static or DHCP), addresses, routes and resolver servers, which
`ifconfig` shows and the resolver reads, and no administrative reader
takes them from the published tables.

### Sockets act for one domain

The grant starts the domain's sockets, except connections accepted on
the domain's listeners, which the interface process starts; every socket
links to its grant and traps exits, so the grant's end reaches it as a
message and it ends, a connection with a RST.

In this document a socket is the network domain's process for it, a
connection, listener or datagram socket. Each serves exactly one socket
process, in the grantee's domain
([The socket process](#the-socket-process)): the one the `connect`,
`listen` or `open` that made it names, or, for an accepted connection,
the one its listener's `accept` request names. It links to that process
before anything else, takes requests from it alone and sends it alone
its pushes and replies, and sends it nothing until it has taken that
process's first message (**Opening**, in
[The socket process](#the-socket-process)); no owner, and no other
process of any domain, is known to it. The link is the one tie between the two in each
direction: the socket takes its socket process's exit as the end of its
socket process, and the socket process takes the socket's exit as the
end of its socket. A socket's pid is encoded only in frames to its socket
process, so the network domain's runtime exports it to the grantee
alone, with `send` only, and no other domain can message it
([design-domains.md](design-domains.md#exports)). A socket receives
messages from other domains wrapped with their origin, as every process
does ([design-domains.md](design-domains.md#the-peer)), and checks each
request as a facet does, through
the admission path generated from the same schema: the request's origin
against the grantee, its operation and arguments against the schema, its
size, and the requests in flight against the socket protocol's limits
([Requests in flight](#requests-in-flight)). The socket process a request names, in
`connect`, `listen` or `open` or in `accept`, must be a
pid of the grantee's domain. Every later request must then name the
socket's own socket process as its sender
(`{erx_net, SockProc, Body}`); one that names any other process is
dropped and counted, as a message that names no socket is. This check
is not an authority boundary: the domain is the unit of authority, and
any process of the grantee's domain may use the socket through its
socket process, as any process of a node may use a stock socket it
knows. What it gives is that nothing reaches a socket around its socket
process, so the ordering of [Ordering](#ordering) holds.

A connection waiting in a listener's backlog counts toward that
listener's backlog, which is bounded. It becomes one of the grant's
sockets at `accept`, and `accept` answers `{error, emfile}` while the
grant has no socket left, leaving the connection queued, as UNIX's
`accept` does.

**The grant's account.** Every reduction a socket spends, on its
socket process's requests and on the packets that arrive for it, is charged to
its grant's account, the facet's account of
[design-domains.md](design-domains.md#facets) extended to the processes
the facet starts ([Decisions](#decisions), 1). The grant's own work, on
`connect`, `listen` and the rest, is charged to the same account as any
facet's is. The account is an `atomics` array that the grant creates and
hands each socket at its start: the reductions spent in the current
period, and the period's number. The period and the share are the
facet's.

* **Charging.** A socket reads `process_info(self(), reductions)` before
  and after each step and adds the difference to the account at once, so
  work that has no reply, as packet work has none, is charged as it is
  done.
* **Pausing.** Before it takes its next message, a socket compares the
  account with the share. While the share is spent, the socket sends its
  grant `{paused, self()}` and then takes only the grant's
  `{resume, Period}` and the `'EXIT'` messages of its links, by a
  selective receive that names only those, so everything else stays in
  its mailbox unread. Meanwhile its packet credit fills, its interface
  drops further segments for it, and the peer's congestion control
  slows; its deadlines wait too, so a retransmission or keepalive runs at
  most one period late.
* **The period's turn.** The grant arms the period's one timer. At each
  turn it subtracts the share from the spent count, never below zero, so
  an overrun is carried into the next period as a debt and an unspent
  share is not carried; it increments the period's number and sends
  `{resume, Period}` to every socket that reported itself paused. A
  `{paused, Pid}` that arrives when the account is no longer spent, after
  a turn the socket did not see, is answered with `resume` at once, so no
  socket waits a period for a turn it missed.
* **The overrun.** A socket checks before each step and charges after
  it, so a grant's account exceeds the share by at most one step per
  socket, the grant's `sockets` limit times the costliest step. A step is
  finite: a batch of segments is bounded by the socket's credit, and a
  request by the operation schema's bounds. The debt repays the overrun
  in the next period, as a facet's debt repays its requests in flight.

So every reduction the network domain spends is charged to exactly one
place: a grant's account for work in its sockets, and the network
domain's own grant for the interface processes and the drivers
([Untrusted input](#untrusted-input)).

Buffer space is reserved at the grant: a socket asks its grant, with a
local call, before it grows a buffer by autosizing or by a `sndbuf` or
`recbuf` option, and the grant refuses past its `buffers` limit. Each
call names a token the grant made for that socket alone and handed it
at its start, so a reservation is never charged to a socket on the word
of a pid in a message. A connection the grant starts reserves its
initial buffers first and, refused, is answered `{error, enobufs}`; a
connection the interface process starts reserves them as it starts and,
refused, ends with a RST, as FreeBSD answers a completed handshake it
cannot give a socket. The grant holds each socket's reservation and
releases it when the socket exits, by whatever means, or earlier, when
a connection reaches TIME-WAIT with its socket process gone: then its
send buffer is empty, since the peer acknowledged our FIN, its receive
queue was dropped with the socket process, and nothing more can be
queued or delivered. FreeBSD keeps a closed socket's `chgsbsize` charge
until `tcp_close` frees it at the end of 2MSL (`tcp_usr_close` holds the
socket by `INP_SOCKREF`, and `tcp_twstart` only calls
`soisdisconnected`, which empties the send buffer but keeps its
reservation); its per-user limit is unlimited by default, so the
charge costs nothing there. A grant's limit is finite, and a client
that makes many short connections would otherwise hold 96 KiB for each
of them for a minute after closing it.

### Ports and the demultiplexing table

The demultiplexing table, `erx_net_demux` in `erx_net_tables`, maps a
key to the socket that receives for it, its entry `#{pid, credit}`:

* `{tcp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`: a
  connection;
* `{tcp_listen, Family, LocalAddr | any, LocalPort}`: a listener, whose
  entry also holds its grant and its options for accepted connections
  (`erx_tcp_syncache:listener()`), and whose credit is its accept credit;
* `{udp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`: a
  connected datagram socket;
* `{udp, Family, LocalAddr | any, LocalPort}`: a bound one.

Lookup goes from the most specific key to the wildcard, as
`in_pcblookup_hash` does ([Classifying a frame](#classifying-a-frame)). Every insertion goes through `erx_net_bind`,
with `ets:insert_new/2`, so a key is held by exactly one socket by
construction and a race between two binders is decided by ERTS. A
chokepoint check fails the build on any other insertion into the table.

`erx_net_bind` translates FreeBSD's port rules: ephemeral ports from
10,000 to 65,535, chosen at random (`ipport_firstauto`,
`ipport_lastauto`, `ipport_randomized`, `in_pcb.c:122-136`), with
`in_pcb_lport_dest`'s search for a free four-tuple: a random start, then
each port after it in turn, wrapping at the end of the range, until one
is free or the range is spent (`in_pcb.c:830-842`). The binding socket's
step draws the start from its generator with `uniform/2` and returns it
in its bind action, and the funnel walks the range from there with
`ets:insert_new/2`; `{reuseaddr, true}`
as `SO_REUSEADDR`; and `{reuseport, true}` sharing a port only between
sockets of the same grant, where FreeBSD requires the same user
(`in_pcbbind_avail`, `in_pcb.c:912`).

A socket removes its own entries when it ends normally. When a socket
exits abnormally, its grant, which traps the exit, deletes every entry
whose holder is that pid. When a grant ends, `erx_net_tables`, which
monitors every grant, deletes every entry the grant's sockets held. These
are the only two ways an entry outlives its holder, and both are handled
by one owner each.

## The interface towards Erlang programs

### The backend

erXos's OTP adds a third value to `inet_backend`, `erx`, and makes it the
default: `inet:gen_tcp_module/1` and `inet:gen_udp_module/1`, through
their private two-argument clauses, return `erx_gen_tcp` and
`erx_gen_udp` for it. On stock OTP, where that edit is absent, a host
test calls the backend directly
([Running on a development host](#running-on-a-development-host)). A socket is
`{'$inet', erx_gen_tcp, Pid}` or `{'$inet', erx_gen_udp, Pid}`, where
`Pid` is the socket's socket process, a process of the owner's own domain
([The socket process](#the-socket-process)), so `gen_tcp`, `gen_udp` and
`inet` reach the backend through the dispatch they already have. The
socket process builds that term for every message it sends the owner, so
an owner's `receive {tcp, S, Data}` matches as on stock, in any domain.

Each call on an open socket is a local call to the socket process. The
socket process answers what is its own (presentation, `recv`,
`controlling_process`, `close`) by itself, and sends the rest as one
request to its socket. An open is the opener's own call to the grant,
naming the socket process it started (**Opening**, in
[The socket process](#the-socket-process)).

| Call | Answered by the socket process | Request to the network domain | To |
| --- | --- | --- | --- |
| `gen_tcp:connect/3,4` | started by the stub, owned by the caller, which calls the grant | `{tcp_connect, Family, Remote, Port, Opts, Timeout, SockProc}` | grant |
| `gen_tcp:listen/2` | started by the stub, owned by the caller, which calls the grant | `{tcp_listen, Family, Local, Port, Opts, SockProc}` | grant |
| `gen_tcp:accept/1,2` | the listener's socket process starts the new connection's, owned by the caller | `{accept, SockProc, Timeout}`, naming the new socket process | listener |
| `gen_tcp:send/2` | forwarded in pieces within the send credit; the caller waits, behind any earlier `send`, until its last byte is sent, at once when its credit covers it | `{send, Piece}` for each piece of up to 64 KiB, in order, within the send credit the connection granted ([The socket process](#the-socket-process)); nothing answers it | connection |
| `gen_tcp:recv/2,3` | from the bytes it holds, waiting until the deadline, behind any earlier `recv` | none; a waiting recv may grant credit | none |
| `gen_tcp:shutdown/2` | forwarded | `{shutdown, How}` | connection |
| `gen_tcp:close/1` | answered `ok`, then the socket process ends, and its exit closes the socket | none; the exit, through their link | socket |
| `gen_tcp:controlling_process/2` | locally, as `gen_tcp_socket` does | none | none |
| `gen_udp:open/1,2` | started by the stub, owned by the caller, which calls the grant | `{udp_open, Family, Local, Port, Opts, SockProc}` | grant |
| `gen_udp:send/2,3,4,5`, `gen_udp:connect/3` | forwarded; a datagram larger than IP allows is refused here with `{error, emsgsize}` | `{send_to, ...}`, `{connect, ...}` | datagram socket |
| `gen_udp:recv/2,3` | from the datagrams it holds, waiting until the deadline, behind any earlier `recv` | none | none |
| `inet:setopts/2`, `inet:getopts/2` | its own options locally, the rest forwarded ([Options](#options)) | `{setopts, Opts}`, `{getopts, Names}` for the socket's options | socket |
| `inet:peername/1`, `inet:sockname/1`, `inet:port/1`, `inet:getstat/2` | forwarded | `peername`, `sockname`, `{getstat, Names}` | socket |
| `inet:getifaddrs/0`, `inet:gethostname/0`, `ifconfig` | no socket process: the caller calls the grant through `erx_inet:call/1`, which admits the answer ([Untrusted input](#untrusted-input)); `inet:getifaddrs/0` builds its answer from the interfaces' records | `interfaces`, `hostname` | grant |
| `erx_gen_icmp:open/0`, which `ping` uses | started by the stub, owned by the caller, which calls the grant | `{icmp_open, Family, SockProc}` | grant |

A socket closes when its owner exits, as a `gen_tcp` socket does: the
socket process monitors its owner. The pushed messages are stock's:
`{tcp, S, Data}`, `{tcp_closed, S}`, `{tcp_error, S, Reason}`,
`{tcp_passive, S}`, `{udp, S, Address, Port, Data}`, `{udp_passive, S}`.
Active modes `true`, `false`, `once` and `N` behave as stock. `{active,
N}` takes `N` from -32768 to 32767 and adds it to the count the socket
already has when it is in `{active, M}`, rather than setting it, as
stock does (`inet.erl:932-941`, `gen_tcp_socket.erl:3124-3138`): a sum
over 32767 is refused with `{error, einval}`, and a count that reaches
zero or less, by deliveries or by the addition, makes the socket passive
and sends `{tcp_passive, S}` or `{udp_passive, S}`. In `true` mode, as
on stock, nothing limits what reaches the owner's mailbox but
how fast the owner reads it; what limits the network domain is the
socket process's credit ([The socket process](#the-socket-process)).

In passive raw mode `recv(S, 0)` takes what the socket process holds, or
waits for the next push, and `recv(S, Length)` waits for exactly `Length`
bytes, up to stock's 64 MiB (`TCP_MAX_PACKET_SIZE`), as stock's does
(inet_drv's `tcp_recv`). While a recv waits, the socket process grants
the credit its `Length` needs, so the bytes for it leave the connection's
receive buffer and the window reopens for the rest of the recv, as
FreeBSD's `soreceive` copies them out to the caller under `MSG_WAITALL`
and calls `pru_rcvd` before it sleeps; held in the receive buffer, they
would leave a recv near the buffer's size waiting for the last part of a
segment, which the sender's silly window avoidance sends only as a
persist probe. What a waiting recv holds is the owner's domain's memory,
as stock's is the node's. A recv that times out leaves the bytes held for
the next one, as stock does. A recv still waiting when `setopts` turns
the socket active is answered `{error, einval}`, as a recv of an active
socket is; stock's driver leaves it waiting until its timeout. When the
peer's FIN leaves fewer bytes than a waiting recv asks for, the recv
answers as stock's does (`tcp_recv_closed`): `{error, closed}`, the
bytes discarded, and every recv after it `{error, enotconn}` and a
send `{error, closed}`, as stock's do once its driver has closed the
socket. In the connection, as in the reassembly
queue, a payload smaller than a quarter of its frame is copied out as it
is queued, so tiny segments do not keep their frames alive.

The packet modes (`{packet, 1|2|4}`, `line`, `http`, `http_bin` and the
rest) frame the stream in the socket process with
`erlang:decode_packet/3`, where stock frames it in its inet driver, so an
owner receives whole packets, and a send in a packet mode gets its
header there. Framing sits where the unpresented bytes are, so a change
of packet mode between two packets applies to every byte not yet
presented, as on stock: an HTTP server that reads its headers in
`http_bin` and its body in `raw` gets the body's first bytes in `raw`,
though they arrived with the headers. That is ERTS's C parser running
on peer data in the owner's domain, as stock runs it in every node; it
gets a fuzz target over every mode the options offer, and no client's
framing runs in the network domain ([Decisions](#decisions), 6).

Where stock OTP's result depends on the kernel beneath it, and the oracle
runs stock on Linux, the stack gives FreeBSD's result, and each such case
is a documented difference with a test. IPv6-only sockets by default are
one: Linux's default admits IPv4-mapped addresses, FreeBSD's does not.

### The socket process

Every socket is two processes: its socket, the connection, listener or
datagram socket in the network domain, and its socket process, a
`gen_statem` of `erx_gen_tcp` or `erx_gen_udp` in the owner's domain, the
same shape as stock OTP's `gen_tcp_socket` (`gen_tcp_socket.erl:1565`).
The construction is one rule:

**The socket process is the only party that talks to the socket, and the
only party that talks to the owner about it.** Every request a program
makes reaches the socket process as a local call, and the socket process
sends it on; every reply and every push comes back to the socket process,
on the one lane from the network domain to its domain; and the socket
process alone sends the owner the socket's messages, which it builds
itself from checked parts.

**Where the client half lives.** A socket's client half, its owner, its
active mode and framing, the bytes pushed to it and not yet presented,
its credit and the calls waiting on it, lives in the socket process and
nowhere else. Three duties need a process of the owner's domain that is
neither the owner nor the socket:

* any process of the domain may call a socket it knows, as on stock, and
  an owner's code serves no calls, so state that every caller shares
  cannot live in the owner;
* in active mode the owner's `receive {tcp, S, Data}` must match a
  message made in its own domain, since every message from the network
  domain arrives as `{erx_origin, D, Msg}`, with no exception, and only a
  protocol's owner takes the envelope off, in its own receive (D18 of
  [design-domains.md](design-domains.md#invariants)); the owner's code is
  not that receive;
* a passive owner, often a `gen_server`, takes whatever reaches its
  mailbox, so the socket's pushes may go only to a process that expects
  them.

The socket in the network domain cannot hold the client half either:
across domains its active mode would still need a process of the
owner's domain to take the envelope off, a passive `recv` would cross the
lane twice instead of being a local call, and framing would run on a
client's peer data in the network domain ([Decisions](#decisions), 6).
So the socket process is erXos's counterpart of stock's inet port, and
its hop, a local round trip per call and a local message per delivery,
is the price of that port being a process
([Alternatives considered](#alternatives-considered)). What the protocol
removes instead is every message on the data path that the hop does not
need: no transfer of bytes, in either direction, is answered, because
each side sends bytes only within credit the other side granted
(**Credit, both ways**, below).

The socket process makes its requests and takes its pushes in the socket
protocol, a closed set of shapes, each `{erx_net, Sender, Body}` with
`Sender` the pid of the process sending it:

```erlang
%% Socket process to socket.
-type request_body() ::
      {call, N :: non_neg_integer(), Request :: erx_net_admit:request()}
    | {send, Piece :: binary()}             % a connection's bytes, within the
                                            % send credit it granted; never
                                            % answered
    | {credit, Bytes :: pos_integer()}.     % receive credit, for every kind
                                            % of socket

%% Socket to socket process.
-type push_body() ::
      {reply, N :: non_neg_integer(), Result :: term()}
    | {credit, Bytes :: pos_integer()}      % a connection's send credit:
                                            % room in its send buffer
    | {data, [binary()]}                    % in-order bytes, the receive queue's
                                            % pieces as they are: at most 64 binaries
                                            % and at most a piece in all
    | {datagram, inet:ip_address(), inet:port_number(), binary()}
                                            % one whole datagram
    | {echo, inet:ip_address(), Ttl :: 0..255, Seq :: 0..65535, binary()}
                                            % one echo reply, an echo
                                            % socket's only push
    | eof                                   % the peer's FIN, after every byte
    | {error, erx_sock_admit:end_reason()}. % the socket has ended; its last push
```

`N` is the socket process's count of its calls, so a reply names the
call it answers and calls answer in any order. A stream's bytes are not
a call: the socket process sends a connection `{send, Piece}` only within
the send credit the connection granted, and the connection takes the
piece into its send buffer and answers nothing. The socket process never
waits for its socket: it sends a call, keeps the caller's `From` under
`N`, and goes on taking pushes and calls, and a `send` that waits for
credit waits in the socket process, so an owner in active mode receives
data while its own `send` waits, as with stock's inet driver, and a
`close` or `shutdown` never waits behind it. Two peers that both send
before they read would otherwise deadlock on each other's full receive
windows. Concurrent callers wait in the socket process, never at the
funnel ([Requests in flight](#requests-in-flight)).

**The socket process never suspends.** Everything a socket's callers
and owner wait on happens in the socket process: it answers calls, ends
a `send` or a `recv` at its deadline, stops when its owner exits and
presents the pushes. So nothing may stop it running, and the one thing
that could is its own traffic to the network domain. A frame for a full
lane waits in the sender's runtime, and once that domain's queue there
has passed the busy limit, 1 MiB, ERTS suspends a process that sends to
the domain ([design-domains.md](design-domains.md#flow-control)), and
suspends one that links to, monitors or demonitors a process there too,
after queuing the signal: `link/1`, `monitor/2` and `demonitor/1`
prepare their signal with `no_suspend` 0 (`bif.c:334`, `:909`, `:607`),
and the send's last phase suspends such a caller while the entry is busy
(`dist.c:3824-3842`). A network domain that stops draining its lane from
a client would then freeze every socket process of that client that
touched it, and one socket's bulk send would hold up another socket's
`close`. Three rules take every such site away:

* **It is spawned with `{async_dist, false}`,** whatever its runtime's
  default. ERTS skips the busy check for a process with the
  `async_dist` flag, so its `nosuspend` sends are never refused and its
  frames join the queue past the busy limit (`dist.c:3412-3419`), and a
  runtime started with `+pad true` gives the flag to every process it
  spawns (`erl_init.c:1382`, `erl_process.c:12458`). Every socket
  process is started through `erx_sock_out:start/2`, which passes the
  option to `gen_statem:start/3` in its `spawn_opt`, and no module of
  the socket process calls `process_flag(async_dist, _)`, so the flag
  is off for its whole life in any runtime.
* **The socket process sends to its socket only through
  `erx_sock_out:send/2`,** which sends with `erlang:send/3` and the
  options `[nosuspend, notify]` and answers `ok` or `refused`. ERTS
  answers `ok` once the frame is queued for the lane, and refuses
  without queuing anything while the domain's queue is busy, as stock
  ERTS refuses a `nosuspend` send (`dist.c:3417-3419`). With `notify`,
  the runtime then sends the refused process `{erx_lane_ready, Node}`,
  once, when the queue stops being busy or the connection ends (edit 67
  of [design-runtime.md](design-runtime.md#connections-in-erts)). Within
  one domain, `Origin` `local`, the outlet sends plainly: a send within
  a runtime never suspends.
* **It makes no link, monitor or call towards the network domain.** Its
  socket links to it, which needs the `send` and `link` rights that the
  socket process gives the network domain as it starts (`expose/2`,
  [Two places, four seams](#two-places-four-seams)), and it traps exits
  before it exposes itself, so the socket's exit reaches it as a
  message whatever ended the socket: its own end, a kill, its grant's
  end, or the network domain's end as `noconnection`. Whoever opens a
  socket calls the grant, not the socket process (**Opening**, below).

A build check holds all three: only `erx_sock_out` starts a socket
process, and only it sends, links, monitors or calls in the socket
process's modules, none of which sets `async_dist`
([Build checks](#build-checks)), so the property rests on one module,
not on every send site remembering an option or every start
remembering a flag.

**What a refusal leaves where.** The core decides what goes to the
socket, and the shell commits a decision only once the outlet has taken
it. `erx_gen_tcp_core:next_out(Core)` and its datagram twin answer
`{Msg, Core1}` or `none`, a pure function of what the core holds: a call
waiting for a place, the receive credit the half-target rule makes due,
or the next piece the waiting send's credit allows. The shell sends
`Msg`; on `ok` it keeps `Core1` and asks again, and on `refused` it
keeps `Core`, marks the lane refused and sends nothing more until the
notification, when it asks again. So a refused item stays where items
already wait, and no queue of refused messages exists:

* a refused piece stays in its `send`'s data, and its credit stays
  unspent;
* a refused call stays in the waiting-call queue and takes no place in
  flight ([Requests in flight](#requests-in-flight));
* refused receive credit stays a shortfall not yet granted: the credit
  outstanding counts only grants the lane took, so the next grant
  carries the whole shortfall in one message however many were refused.

While the lane is refused the socket process goes on taking pushes,
calls and timers: it presents data, answers what it can answer locally,
meets deadlines and stops when its owner exits. Order needs nothing
more: nothing is sent twice, a send's bytes go in order because only
one send sends at a time, and a `shutdown` is a call, offered only
after the bytes of every send already answered. An `{erx_lane_ready, Node}` it did not ask for can come only
from a process of its own domain, since a message from another domain
arrives in its envelope; it costs one more attempt, refused again while
the queue is busy.

**What waits for an undrained lane.** The client's queue for the
network domain is bounded as every queue for a peer is (D12 of
[design-domains.md](design-domains.md#invariants)): the busy limit,
plus one frame for each process caught between ERTS's busy check and
its enqueue. The check reads the busy flag without the queue's lock
(`dist.c:3418`), and the enqueue takes the lock later (`dist.c:3786`)
and queues the whole of a `nosuspend` send's frame, whatever the queue
then holds (`dist.c:3765-3771`). A send can yield between the two while
it encodes, since `remote_send` prepares it with `no_trap` 0
(`bif.c:2479-2481`, `dist.c:3727-3728`), so the overshoot is one frame per
process rather than per scheduler. A socket process is one process, so
its share past the limit is one frame: a piece and its header.
Everything else it has to send waits in the socket process, in the
places above, so a network domain that stops draining makes a client
hold the callers' own data, their waiting calls and one count of
receive credit per socket, and nothing for its grants or answers:

* receive credit is granted only as the lane takes it, so a socket
  process that keeps consuming pushes while its lane is stalled holds
  one integer, not a message per half target;
* a reply, forged or not, frees a call's place, and the next call still
  goes only when the lane takes it, so freeing places queues nothing;
* send credit lets the socket process send sooner only bytes its callers
  gave it, and only as fast as the lane takes them.

While the lane is stalled, a `send` that fits its credit is answered
`ok` once its last piece is queued, as FreeBSD answers a `send` once its
bytes are in a send buffer that a stalled network never drains; a
`send` that waits meets its `send_timeout`; `close/1` is answered and
the socket process stops; and the socket process stops when its owner
exits. Its exit then waits for the lane as any signal does: ERTS takes
a process out of its process table and fires its local links and
monitors before it sends any signal to another domain (the exit phases,
`erl_process.c:14150-14166`, and "time of death", `:14370-14373`), so
its callers and owner see it gone at once, and only its exit signal to
the socket waits, in the exiting process, until the lane drains, behind
every frame it sent.

**What a queued piece keeps alive.** A piece is a sub-binary of the
binary its `send` was cut from, and ERTS's encoder puts that binary
itself into the frame (`external.c:3974`, `:4204`), so a queued piece
would keep the whole of it alive, after the send is answered, after it
times out and its caller drops `Rest`, and after the socket process has
stopped, for as long as the lane is stalled. So every piece is a binary
of its own size, made as the core cuts it (`erx_gen_tcp_core:piece/2`):
a piece cut from a binary whose `binary:referenced_byte_size/1` exceeds
the piece is copied with `binary:copy/1`, and a send's iodata is joined
a piece at a time rather than whole, so each byte of a send is copied
at most once. What a stalled lane keeps of a client's
sends is then exactly what the queue bound counts, the busy limit plus
one frame per sending process, whatever the size of the binaries the
callers sent, however each send ended, and however long the network
domain leaves the lane undrained. No other rule needs to know which
pieces can still be queued when. The copy costs one pass over the bytes
of a send whose data is cut from larger binaries, a bulk send from one
large binary among them, and nothing for data that is already in
binaries of a piece or less; the watch list holds its cost to a bulk
send ([todo-performance.md](todo-performance.md)).

**Opening.** Opening a socket is the one exchange outside the socket
protocol, and the socket process takes no part in it but to receive
its socket. The process that calls `gen_tcp:connect`, `gen_tcp:listen`
or `gen_udp:open`, the opener and the socket's owner, starts the socket
process, which exposes itself to the grant's domain as it starts; then
calls the grant, a facet, as any client calls a facet
([design-domains.md](design-domains.md#facets)), through
`erx_inet:call/1`, with a request that names the socket process; the
grant starts the socket, which links to that socket process before the
grant answers; and the opener hands the answer's socket to the socket
process, as the listener's socket process hands an accepted connection
to the socket process it started (**Accepting**, below). The opener's
call is an ordinary call, which may suspend the opener behind an
undrained lane as any call to a stalled domain may, while it waits for
the open anyway. The answer, `{ok, Socket}`, passes `erx_sock_admit` as
every message from the network domain does
([Untrusted input](#untrusted-input)): `Socket` must be a pid of the
grant's own node, `node(Socket) =:= node(Grant)`, so a network domain
that names a process of a third domain is refused at the open, with
`{error, badarg}`, and every later push check compares against a pid
the network domain owns. A socket process that has died by the time its
socket links to it makes the link answer `noproc`, and the socket ends.

**Nothing crosses before the first contact.** The network domain knows
the socket process's pid from the open request on, so it could push to
it, or link and exit to it, before the socket process knows which pid
is its socket; anything it kept for later would be held unaccounted,
outside the credit that bounds every push. So the protocol has a first
contact, and the socket process keeps nothing from the network domain
before it:

* a socket sends its socket process nothing, no push and no credit,
  until it has taken that process's first message, which the socket
  process sends only once it holds its socket: a connection's or
  datagram socket's first receive credit, granted at the hand-over, or
  a listener's first `accept`; a socket that ends before then ends by
  its exit alone, which the link carries;
* in `opening` the socket process takes the hand-over and the deaths
  of its owner and of the listener's socket process that started it,
  and postpones only calls of its own domain, which no process makes
  before the open has returned the socket, so what it postpones is its
  own domain's doing;
* anything from the network domain in `opening`, a push, a reply or a
  link exit, ends the opening: the socket process stops with
  `econnaborted`, the hand-over meets a dead process and the open
  answers `{error, econnaborted}`, and the socket, if it lives, takes
  the exit through its link and closes. A correct network domain sends
  nothing there but the exit of a socket that ended before its first
  contact, whose open fails as an open whose connection was aborted
  does (FreeBSD's `accept` answers `ECONNABORTED` for one).

So a socket process keeps nothing from the network domain before it
holds its socket, and after it, only what passes its admission and its
credit. The first contact costs a connection's first send one lane
round trip after the open returns, while the connection's first grant
of send credit answers the socket process's first receive credit; the
watch list holds that wait ([todo-performance.md](todo-performance.md)).

**States.**

| State | The socket process holds | Takes | Leaves for |
| --- | --- | --- | --- |
| `opening` | its owner, the opener; for an accepted connection, the listener's socket process that started it | the hand-over of its socket, from its opener or from the listener's socket process; the exit of its owner and of that process; postpones calls of its own domain; stops with `econnaborted` at any message or exit from the network domain; drops and counts any other message, as in every state | `open` or `listening` with its socket, sending its first message; on a refused open its opener stops it |
| `open` | a connection or datagram socket: its owner, its active mode and presentation options, the bytes or datagrams it holds, the receive credit it granted, a connection's send credit and the sends whose bytes wait for it, each with its deadline, the end reason its sends have not yet been shown, a waiting `recv`, its calls in flight and the calls waiting behind them | every call, push and exit | `closed` |
| `listening` | a listener: its owner, its `accept` calls in flight, each with the socket process it started for its caller, and the calls waiting behind them | every call, push and exit | `closed` |
| `closed` | the bytes still held and the end its owner has not been shown, which wait for the owner in passive mode | `recv`, which takes what is held and then meets the end; `setopts` while the end waits, so the owner can be shown it in active mode; `close/1`, which answers `ok`, and its owner's exit; every other call answers as stock's closed socket does | stops |
| `{transfer, NewOwner, State}` | `controlling_process/2` under way, and what `State` holds | the owner's second call and the owner's exit; every push, exit and deadline, stepped as in `State` with nothing presented to the owner, so the core holds what arrives as in passive mode, within the credit it granted; postpones the other calls of its own domain | `State`, with `NewOwner` as owner, presenting what was held |

The state is the effect shell's; what is presented, granted and replied
is decided by a pure step, `erx_gen_tcp_core:step(Event, Core) ->
{Core, [Action]}` and its datagram twin, whose actions are messages to
the owner, replies to callers, requests and grants to the socket, and
`stop`, as every stack process decides
([One owner, one step](#one-owner-one-step)). The core reads no clock;
the socket process arms a timer for each deadline it holds, a waiting
recv's, of a connection or of a datagram socket, and each waiting
send's (**Send credit**, below), as named `gen_statem` timeouts, and
steps on their expiry. The deadlines of `connect` and `accept` are not
its own: the opener passes `connect`'s timeout to the grant, and the
listener's socket process passes `accept`'s to the listener, whose
timers run on the stack's clock. The virtual clock of the host runs
([The clock](#the-clock)) does not reach these timers, so those runs
call `gen_tcp:recv` and `gen_udp:recv` without a timeout and set no
`send_timeout`. A timer's expiry is an event in the socket process's
mailbox, taken in order behind the pushes already there, so a recv
whose deadline passes behind a backlog of pushes takes those pushes
first: it is answered with their bytes if they complete it, and
otherwise with `{error, timeout}`, late by the time they take, and a
send whose deadline passes behind a grant of credit sends what the
grant allows before its deadline is taken. Stock's driver takes its
input in order too, and a second timer would not answer sooner.

At `eof` with `exit_on_close` true, the default, the socket process in
active mode presents what it holds, then `{tcp_closed, S}`, sends `close`
and moves to `closed`. In passive mode, whether its owner chose it or an
active count ran out, the end waits for the owner, as in stock's inet
driver, which meets the peer's FIN only when it reads: the socket stays
`open` and its sends go on until a recv that what is held cannot
complete is answered `{error, closed}` (`tcp_recv_closed`), the recvs
after it `{error, enotconn}`, or the owner
turns the socket active and is shown what is held and `{tcp_closed, S}`;
then it sends `close` and moves to `closed`. With `exit_on_close` false
it stays `open`, its reads answer as closed and its sends go on.

At `{error, Reason}`, or its socket's exit, `{'EXIT', Socket, _}`, the
socket is gone: the socket process sends `close`, moves to `closed` and
answers every call it holds `{error, closed}`, except the sends waiting
for credit, of which the first meets the end's reason as **Send credit**
below says. Since it traps exits, an exit from any other process reaches
it as a message too: one from a process of its own domain stops it with
that reason, as the exit would stop it if it did not trap, and one from
another domain is dropped and counted, since only its socket is linked
to it there. In active mode it presents what it holds,
then `{tcp_error, S, Reason}` where stock shows the reason (`econnreset`
only under `show_econnreset`) and `{tcp_closed, S}`. In passive mode the
end waits for the owner as above, and the first recv that what is held
cannot complete is answered with the error. The owner is shown the first
end only: after `eof` the stream is whole, and a later end means only
that the socket is gone. A socket that exits without a last push, killed
or ended with its domain, is taken as `{error, econnaborted}`; a push
after the socket process has closed is ignored.

**Accepting.** `gen_tcp:accept/2` calls the listener's socket process,
which starts a socket process for the caller, owned by it, and sends its
listener `{accept, SockProc, Timeout}` naming the new one. The listener
binds the connection it hands out to that socket process, and the
connection links to it, before the listener answers, and the listener's
socket process hands the new one its socket
and answers the caller with the new socket; on an error or a timeout it
stops the new socket process and answers the error. Many callers may
accept on one listener at once, as ranch's acceptors do, each under its
own `N`. The new socket process grants its first receive credit once it
holds its socket, and the connection pushes nothing, its first grant of
send credit included, until that credit arrives (**Nothing crosses
before the first contact**, above). A connection that ends before then
ends by its exit, which stops the new socket process in `opening`; the
hand-over meets a dead process, and the caller's `accept` is answered
`{error, econnaborted}`.

**Ordering.** One lane carries everything between a socket and its
socket process, in send order (D9 of
[design-domains.md](design-domains.md#invariants)), the socket's exit
included, and the socket process is the one sender of the socket's
messages to its owner and the one replier to its calls. So the owner sees
the socket's messages and its calls' replies in the order the socket
process made them: nothing is presented after the reply to
`inet:setopts(S, [{active, false}])`, with no message to the network
domain, and a push that arrived before a reply is presented before that
reply is given. No program holds a socket's pid, so no request reaches a
socket around its socket process to overtake one. The same lane carries
a connection's bytes, its `shutdown` and the socket process's exit,
which `close/1` brings, in the order the socket process sent them, so
the bytes of a `send` answered before a `shutdown(S, write)` or a
`close/1` reach the send buffer before the FIN is queued behind them,
though the send was answered before they reached the connection: a
send is answered only once its last piece is queued, and the
`shutdown`, a call, and the exit come after it in the lane.

**The protocol's owner.** Every push from another domain arrives as
`{erx_origin, D, {erx_net, Socket, Body}}`
([design-domains.md](design-domains.md#the-peer)), and the socket process
is the owner of the socket protocol on its side: it alone takes that
envelope off, through `erx_sock_admit`, and only for its own shapes. It
takes a push only when `D` is the origin its grant's domain was found
with ([Two places, four seams](#two-places-four-seams)), `local` meaning
bare messages, and `Socket` is its own socket. A message that fails
either test is not its socket's and is dropped and counted as an
unknown message; one from its socket that breaks the protocol aborts the
socket ([Untrusted input](#untrusted-input)). It is started without the
`{erx_serve, any}` option, so a call from another domain is an unknown
message too, and a socket used from another domain fails at once in the
stub, which compares the socket process's node with its own and answers
`{error, einval}`. Since the stack is erXos's own application under
`erlang/`, the source check of D18 over OTP's modules does not list it;
the stack's own build check names `erx_sock_admit` and `erx_net_admit` as
the only modules of its two applications that match `erx_origin`
([Build checks](#build-checks)).

**controlling_process.** The owner is known only to the socket process,
so moving a socket is a local operation, done as `gen_tcp_socket` does
it (`gen_tcp_socket.erl:686-711`, `:1874-1910`): the owner's first call
moves the socket process to `{transfer, NewOwner, State}`, in which it
presents nothing; the stub moves the socket's messages already in the
caller's mailbox to the new owner; its second call switches the
owner's monitor and leaves the state, and what arrived meanwhile is
presented to the new owner in order. During the transfer every push
is admitted, counted against the credit and stepped as in `State`,
with presentation held, so the core keeps what arrives as it keeps it
in passive mode, within the target its credit allows, and its grants
stop when the target is full; an end, an abort and a send's deadline
are taken as in `State`. Nothing from the network domain is postponed,
so a transfer that a caller never finishes holds no more than a
passive socket. The network domain takes no part.
A new owner of another domain is refused with `{error, badarg}`, as
stock's `port_connect` refuses a process of another node, so a socket
never has an owner outside its socket process's domain.

**The owner's exit, `close/1` and the socket process's exit.** All
three end at the same place. When the owner exits, the socket process
stops. At `close/1` it answers every call it holds as stock's closed
socket answers it, answers `ok` and stops, so `close/1` never waits for
the lane and sends no request of its own. When the socket process
stops, however it stops, its socket takes the exit through their link
and closes as `close/1` asks: a connection sends FIN, or RST under a
zero `linger`, and goes on to TIME-WAIT without a caller. When the
client's domain ends, the exit arrives as `noconnection` and the
grant's end follows
([What fails and what survives](#what-fails-and-what-survives)).
A socket process that stops while a call is in flight leaves its
socket to answer a dead pid, which the funnel drops. Its exit signal
travels on its lane behind every frame it sent, those still waiting in
its runtime's queue included
([design-domains.md](design-domains.md#links-monitors-and-exits)), so
the bytes it sent within its send credit are in the send buffer before
the connection closes, and the FIN follows them; the bytes of sends
still waiting for credit go with the socket process, and their callers
get `{error, closed}`, as every call to a stopped socket process does.

**Credit, both ways.** Bytes cross between a socket and its socket
process only within credit that the side receiving them granted, in
bytes, and no transfer of bytes is answered. Receive credit flows from
the socket process to its socket, for every kind of socket; send credit
flows from a connection to its socket process.

**Receive credit.** The socket process grants its socket credit in
bytes, for a connection and for a datagram socket alike. The socket pushes only
within the credit it holds, at most a piece per push
([Message sizes](#message-sizes)), a datagram whole and only when the
credit covers its cost, and keeps the rest: a connection in its
receive buffer, whose free space is the window it advertises, and a
datagram socket in its queue up to its receive buffer, past which it
drops and counts, as FreeBSD drops on a full receive buffer. The socket
process keeps what it holds plus the credit outstanding at its target:
its `buffer` option, the user-level buffer of stock's `inet`, whose
default is the socket's receive buffer, and for a datagram socket never
less than 128 KiB. A waiting `recv(S, Length)`, or a packet whose header
announces more, raises the target to what it needs, up to 64 MiB or
`packet_size`. The shortfall is the target less what it holds and the
credit outstanding, and the socket process grants it when it reaches
half the target, so credit costs one message per half target received,
and at once when a waiting `recv` or a packet in progress needs more
than it holds and has outstanding, so no recv waits for bytes its socket
holds but may not push.

A datagram costs its length in credit, and an empty datagram one byte,
on both sides: the socket pushes it only when its credit covers
`max(1, byte_size(Data))` and the socket process counts it so. An empty
datagram is never free, so a peer that floods a socket with empty
datagrams spends the credit as any other sender does and is held to one
credit message per half target, 65,536 empty datagrams by default.

Between grants, what the socket process holds plus the credit
outstanding therefore stays above half the target, so once it holds
nothing, its credit outstanding is more than half the target. A datagram
socket's floor of 128 KiB, twice the largest UDP payload of 65,527
bytes, makes that enough for any datagram, so no datagram waits in its
socket for credit while the socket process holds nothing. In passive
mode a datagram socket thus holds up to its receive buffer in the
network domain and its socket process up to its target, where stock
holds only the kernel's receive buffer and its driver reads one datagram
per recv: a departure of at most the target per socket, 128 KiB by
default, in the owner's own memory, for the lane crossing that a read
per recv would cost. Both bounds are bytes, as stock's `recbuf` is. So:

* in `{active, true}` the socket process presents each push at once, so
  it holds nothing and grants by the half-target rule, one credit
  message per half target received: the owner's mailbox is bounded only
  by how fast the owner reads, as on stock, and the lane paces the
  pushes;
* in `{active, once}` after one delivery, and in `{active, N}` when the
  count runs out, the socket process stops presenting, sending
  `{tcp_passive, S}` or `{udp_passive, S}` for a count only, as stock
  does; what arrives fills its target, its grants stop, and
  the connection's receive buffer fills and its window closes, as
  stock's socket stops reading the kernel's buffer. `inet:setopts(S,
  [{active, N}])` is answered locally and presents what is held at once,
  so an owner that re-arms after every packet, as cowboy may, costs no
  message to the network domain;
* in passive mode a recv is answered from what is held, a local call.

A connection therefore holds at most its receive buffer in the network
domain, whatever its owner does, and its socket process at most its
target, in the owner's own memory.

**Send credit** is the same rule turned round, for the bytes a
connection sends. The connection grants its socket process credit in
bytes, room in its send buffer, and the socket process sends
`{send, Piece}` only within the credit it holds, which the piece spends;
nothing answers it. Three counts decide every grant:

* the high watermark, FreeBSD's `sb_hiwat`, which `sndbuf` and
  autosizing set;
* the bytes the send buffer holds;
* the credit outstanding: granted, and not yet spent by a piece that
  has arrived.

**A buffer never shrinks below what it has promised.** The send
buffer's size, the room its grant reserves, is the larger of the high
watermark and the bytes held plus the credit outstanding. The high
watermark rises only after the grant has reserved the growth
([The TCP core](#the-tcp-core)), so while it only grows the size is
the high watermark. A `sndbuf` that shrinks it lowers the high
watermark at once, and the size only as the peer acknowledges the bytes
held and pieces spend the credit; each step that lowers the size
releases the difference at the grant. So credit already granted is
neither stranded nor uncharged: the socket process spends it as it was
granted, its bytes fit the size, and the grant charges them until they
leave. A client that shrinks a buffer and grows it again escapes no
charge, since the reservation never falls below what the buffer holds
and has promised. FreeBSD's `sbreserve` lowers `sb_hiwat` the same way and
leaves the bytes already in the buffer (`uipc_sockbuf.c`); the size kept
for the reservation is what makes that safe where the grant's limit is
finite.

**The grant rule.** The shortfall is the high watermark less the bytes
held and the credit outstanding, when that is more than zero. After
each step, beside its pushes of received bytes, the connection grants
the shortfall:

1. when it reaches half the high watermark, so a bulk send costs one
   credit message per half buffer the peer acknowledges, and a fresh
   connection's first push, which follows its socket process's first receive credit, grants its whole high watermark;
2. or when no credit is outstanding and no acknowledgement the
   connection waits for will free room, whatever the shortfall: the
   peer has acknowledged every byte sent (`snd_una` equal to
   `snd_max`), or it offers a zero window (`snd_wnd` of 0), so that what
   is unacknowledged is a window probe or bytes the closed window holds
   back.

The rule is a pure function of the three counts and of those two
comparisons. The second clause is its progress rule. The socket process
spends all the credit it holds whenever a send waits, so a connection
with no credit outstanding may have sends waiting behind it. While
bytes are unacknowledged in an open window, an acknowledgement or the
retransmission timer brings another step, and each step applies the
rule again, so a waiting send gets credit at the step at which the peer
has acknowledged half the buffer or everything sent, whichever comes
first, or the connection ends and the send is answered with the end.
In a zero window the connection persists, and FreeBSD's probe sends a
byte past the window that the peer acknowledges without taking
(`tcp_output.c`'s `TF_FORCEDATA`, `erx_tcp_output.erl`), so `snd_una`
stays below `snd_max` and no acknowledgement frees anything until the
window opens: the second clause counts that state as idle. Without it, a
full buffer behind a zero window, with a probe out and `sndbuf` then
raised by less than half the buffer, would leave the new room ungranted
for as long as the window stays shut, and without the second clause at
all, a peer that acknowledges a quarter of a full buffer and then
closes its window would do the same: the first clause waits for
acknowledgements that a closed window does not bring, and a one-byte
`send` would wait for room the buffer has. A zero window with real
bytes unacknowledged also meets the clause, which only grants room the
buffer has a step sooner. While credit is outstanding the second clause
does not apply, so a request-reply exchange, which spends a little of a
large credit and is then acknowledged, costs no credit message; its
requests cost one per half buffer they add up to.

The socket process takes a `send` call's data and sends it in order,
through the outlet, in pieces of at most a piece each, cut also where
its credit ends; with the rest it waits for the next grant, or for the
lane when the outlet refused, and it answers the caller once the last
byte is queued. So `gen_tcp:send/2` returns once its data is in the
socket's send buffer, as FreeBSD's `send` does, where that buffer spans
the connection's buffer and the credit its socket process holds. This
is FreeBSD's own division of the work: `sosend` waits in the socket
layer until `sbspace` has room and hands `tcp_usr_send` only what fits,
and `tcp_usr_send` never waits (`uipc_socket.c`, `tcp_usrreq.c`). The
socket process is that socket layer, and send credit is `sbspace` carried
across the lane. So:

* a `send` that fits its credit is answered by the socket process at
  once, after one local round trip, and its bytes cross the lane once,
  with no reply, so a request-reply exchange crosses the lane once each
  way;
* a bulk send keeps up to a send buffer of pieces in flight, at one
  credit message per half buffer, not a round trip per piece;
* the connection holds no byte beyond its buffer's size, which its
  reservation at the grant covers, and no `send` waits in the network
  domain;
* bytes past the send credit, or after the socket process has sent the
  connection `shutdown` of its write side or `close`, break the protocol:
  the connection counts the break, aborts with a RST and pushes
  `{error, econnaborted}`, as a socket process aborts a socket whose push
  breaks its receive credit; only a socket process that breaks the
  protocol meets it;
* a grant that would take the credit outstanding past 2 MiB, more than
  the largest send buffer `sbreserve` allows (`sb_max_adj`, about
  1.78 MiB), breaks the protocol the other way, and the socket process
  aborts the socket, as for a push past its receive credit. The check
  keeps a hostile count from growing without end; it is not what bounds
  the client's queue, which the outlet bounds whatever is granted;
* bytes that reach a connection that has already ended are dropped with
  it, and their `send` was answered `ok`: this is the race of a `write`
  with a RST on FreeBSD, and the owner meets the error at its next call
  or as the end the socket process presents.

What a waiting `send` meets follows OTP's socket backend,
`gen_tcp_socket`, for the reasons given below:

* **Its deadline.** A send's deadline starts when the socket process
  takes the call, from the `send_timeout` in force then. It also fixes
  `send_timeout_close` and the packet header for that send, as
  `gen_tcp_socket:send/2` reads them once, before it starts
  (`gen_tcp_socket.erl:557-582`). A send waiting behind another counts
  from its own call, as a second writer of the socket backend waits with
  its own timeout. The deadline is the send's, not the owner's:
  `controlling_process` moves neither it nor the send, and a deadline
  that passes during a transfer is taken then, in order behind the
  pushes before it, as in any state. A `setopts` made while a send waits
  applies from the next send.
* **The deadline passes.** With `send_timeout_close` false the send is
  answered `{error, {timeout, Rest}}`, where `Rest` is a binary of the
  bytes of it not yet sent, its packet header included when none of it
  went. Those bytes never reach the connection, so the stream holds
  exactly what was sent before them, and the caller can finish a partial
  packet as OTP's documentation of `gen_tcp:send/2` tells it to: send
  `Rest` in `raw` mode, then restore the packet mode, as OTP's
  `otp_7816` case does (`gen_tcp_misc_SUITE.erl:7887-7911`). With
  `send_timeout_close` true the send is answered `{error, timeout}`,
  and the socket process sends `close`, behind the bytes already sent,
  and moves to `closed`. `gen_tcp_socket` answers both so (`gen_tcp_socket.erl:583-618`).
* **The write side is shut.** A send that meets its write side shut,
  waiting when `shutdown(S, write)` or `shutdown(S, read_write)` is
  made or called after it, is answered as the socket backend answers a
  send the kernel refuses with `EPIPE`: `{error, closed}`, or
  `{error, econnreset}` under `show_econnreset`, and the socket then
  closes, so the sends behind it meet a closed socket, as **The end**
  below says (`gen_tcp_socket.erl:932-933`, `:2739-2792`). Stock's inet
  driver answers `{error, closed}` and closes the socket too
  (`tcp_send_error`). The socket process sends no byte after the
  `shutdown`, so none breaks the protocol.
* **`close/1`.** Every waiting send is answered `{error, closed}`, its
  unsent rest dropped, as the socket backend's blocked writer meets its
  socket closed, and the socket process stops; the bytes already sent
  reach the send buffer before the FIN, since its exit follows them in
  the lane.
* **The end.** When the socket ends, one send is shown the end's
  reason, curated as `gen_tcp_socket` curates a send's error
  (`curated_error_reason`, `gen_tcp_socket.erl:2777-2792`): a reset, an
  abort or a broken pipe as `econnreset` under `show_econnreset` and
  `closed` without it, and any other reason, `etimedout` for one, as it
  is. That send is the first waiting, the one sending; when none waits,
  the socket process keeps the reason, and while its owner has not been
  shown the end, which in passive mode waits for the owner's `recv`, the
  first send after it is answered with it, as a send on a socket that a
  RST has reset is in the socket backend (`econnreset_after_sync_send`,
  `gen_tcp_misc_SUITE.erl:2242`). Every other send, the ones waiting
  behind the first among them, is answered `{error, closed}`. The socket
  backend does the same: its first writer's `handle_send_error` closes
  the socket and moves to `closed` (`gen_tcp_socket.erl:2739-2770`), and
  a later writer meets the closed state's answer (`handle_closed`,
  `gen_tcp_socket.erl:2170-2189`), `{error, closed}`.

**Which stock send this is.** OTP 29.1.2's two `gen_tcp` backends send
differently. The inet driver writes what the kernel takes, queues the
rest and answers at once, holding a later sender only while its queue
is past `high_watermark`; a send it times out is answered
`{error, timeout}` with its data still queued, to be sent later
(`tcp_sendv` and `tcp_inet_send_timeout` in stock's `inet_drv.c`). The
socket backend's send waits until the kernel has taken all of it and
returns the rest at its timeout. erXos matches the socket backend, for
two reasons. An `erx` socket is not a port, and OTP's own suites, which
`make check-oracle` runs on erXos and compares with stock, expect the
socket backend's results from every socket that is not a port:
`otp_7816` reads `{error, timeout}` from such a socket as nothing sent
and `{error, {timeout, Rest}}` as `Rest` unsent
(`gen_tcp_misc_SUITE.erl:7862-7911`), and the
`econnreset_after_async_send` cases expect a 1 MiB send to a peer that
does not read to wait and fail with the reset, where a port answers
`ok` and queues it (`gen_tcp_misc_SUITE.erl:2862-2918`). And a send
answered only once its bytes are in the send buffer needs no queue
beyond that buffer, so a socket holds its buffer and its credit and
nothing more, and `close` and `shutdown` wait for no bytes ahead of
them. A
program written for the inet driver that matches `{error, timeout}`
with `send_timeout_close` false meets `{error, {timeout, Rest}}`
instead, a documented result of `gen_tcp:send/2` (`gen_tcp.erl:883`);
this is a documented difference with a test.

A datagram socket and an echo socket take no send credit: each send is
a call answered with its outcome, since a datagram's send has an outcome
of its own that FreeBSD's `sendto` returns at once (no route, no source
address, a full transmit queue), while a stream's bytes, once the
stream is open, have no outcome but the stream's end.

Against a reply per piece, send credit adds a counter on each side, a
grant rule of two clauses, one pure function, and a size that keeps
promised room reserved. It removes the send's reply and its `N`, the
rule of one send in flight with its refusal, the connection's waiting
writer and the step that moved the writer's rest into the buffer as
room opened, and the piece of slack the grant's reservation kept for
that writer. The waiting moves to where FreeBSD keeps it, in the socket
layer, and so does every rule about how a waiting send ends.

**What it costs.** One local message per delivery, from the socket
process to the owner, and a local round trip per call, from the caller to
the socket process; a payload of 64 bytes or more crosses that hop by
reference. Across the lane, one message per piece sent and one per
push, a receive credit message per half target received and a send
credit message per half send buffer acknowledged, with one more when a
stalled peer leaves less than half a buffer free, and a socket process
per socket, about the size of stock's `gen_tcp_socket` process, in the
owner's domain. A request-reply exchange on one connection therefore
costs four local messages in the owner's domain and one lane crossing
each way, beside the network domain's own path. In return a passive
`recv`, a `setopts` of active mode and `controlling_process` cost no
lane crossing. A refused send costs one `nosuspend` attempt and one
notification, and only while the network domain's lane is behind. The
local hop's share is measured only within one domain
([Alternatives considered](#alternatives-considered), the caller holding
the socket); across domains the watch list holds the measurement
([todo-performance.md](todo-performance.md)).

**What it needs from the runtime.** Three things. Pid exports: the
socket's pid reaches the socket process in the grant's reply, exported
with `send` by appearing in a frame, and the socket process gives the
network domain `[send, link]` on itself with `erx:export/3` before its
pid appears in the open request, so its socket can push to it and link
to it ([design-domains.md](design-domains.md#exports)); a reply names its
call by the integer `N`, and credit is an integer count in each
direction. Calls to the grant, whose replies go to the caller's alias
and so reach another domain only through the four-word references and
the alias registry of
[design-runtime.md](design-runtime.md#unguessable-references); opening a
socket across domains rests on them. And the refusing send with its
notification, `erlang:send/3` with `[nosuspend, notify]`, edit 67 of
[design-runtime.md](design-runtime.md#connections-in-erts), whose
refusal is stock ERTS's and whose notification is the one change.

#### Message sizes

Every message of the socket protocol fits every receiver, because one
constant bounds the bytes it carries: the **piece**, 64 KiB.

* A push carries at most a piece. A connection pushes its credited
  in-order bytes in as many `{data, Pieces}` pushes as it takes, each a
  flat list of the receive queue's binaries as they are, at most 64 of
  them and at most a piece in all, and a datagram is one push, since a
  UDP payload is at most 65,527 bytes. The count bounds what the list
  adds to a frame, 5 bytes of its encoding per binary, so a peer that
  sends one-byte segments cannot make a push's frame grow past its
  piece and header.
* A request carries at most a piece. The socket process cuts the data of
  a `gen_tcp:send/2` into pieces of at most a piece, each cut also where
  its send credit ends, and sends them in order as `{send, Piece}`
  (**Send credit**, above). A datagram larger than IP allows is
  refused with `{error, emsgsize}` before anything is sent: the socket
  process refuses a UDP payload or an echo request's data over 65,507
  bytes, the most an IPv4 datagram carries after its headers. The
  protocol's bounds, which `erx_net_admit` and `erx_sock_admit` check,
  are 65,527 bytes for a datagram, what the UDP length field allows
  under any IP version, and 65,507 for an echo's data.
* Every other request and reply is bounded by the operation schema,
  `abi/services/net.txt`: the length of an option list, the names
  `getstat` takes, the shape of each operation's reply. The socket
  process checks each request with the validators generated from the
  same schema before it sends it, and answers one the network domain
  would refuse as the network domain would, so no request a correct
  client sends is over a limit. Every atom the protocol carries is one
  the schema names and `erx_sock_admit` mentions, so none is new to a
  receiver's atom table.

Every frame of the socket protocol is therefore at most a piece plus a
header under 1 KiB, the 64 binaries' encoding included: the control
term, the message's tags, the sender's pid and `N`. The grant's replies
are bounded by the same schema, and one of them is larger: an
`interfaces` reply of 64 interfaces with 64 IPv6 addresses each carries
more than 168 KiB in its addresses alone, 42 bytes of encoding for each.
These are the limits a frame meets
on a lane ([design-domains.md](design-domains.md#data-model),
[the funnel](design-domains.md#the-funnel)):

| Limit | Value | Checked by | Past it |
| --- | --- | --- | --- |
| `ERX_FRAME_MAX` | 16 MiB (`abi/erx_abi.txt`) | the sender's runtime | the send fails with `system_limit` |
| the receiver's `max_frame` | 1 MiB by default, set by the receiver's own runtime; at least the protocol's floor in a domain that holds `net`, and in the network domain | the receiver's funnel, on the payload's bytes | the frame is dropped as it passes, and counted |
| the receiver's `max_message_heap` | 8 MiB by default; at least the protocol's floor, as above | the receiver's funnel, on the decoded size | dropped and counted |
| the receiver's `funnel_depth` | 16,384 by default; at least the protocol's floor, as above | the receiver's funnel, on the nesting outside tail positions | dropped and counted |
| the target's request limit | the grant's `max_request`, at least the protocol's floor | the network domain's funnel, on the decoded size of a message to the grant or a socket | dropped before it is queued, and counted |

The decoded-size limits count a binary over 64 bytes as the few words of
its reference (`liberx/erx_etf.c`), so a piece's bytes meet only
`max_frame`, and the request limit and `max_message_heap` meet the rest
of a message, which the schema bounds. A frame is one record that the
receiver reads as its bytes arrive, so a frame longer than the lane is
never cut into fragments to reassemble, and `max_frame` is its only bound
on length.

**Every limit has a floor.** A correct frame dropped by any of these
limits does the same harm: a dropped push loses bytes of the stream and
strands the credit it carried, so the socket process counts it as
outstanding for good and the socket never pushes again, and a dropped
`{send, Piece}` loses bytes of the stream with no error. So the
protocol has one floor for each limit the funnel applies, and every
receiver of the protocol runs at or above all of them. The grant's replies have the same need, since a dropped reply leaves its
caller waiting for good. The generator that makes `erx_net_admit` and
`erx_sock_admit` from `abi/services/net.txt` computes the floors from the
same schema, as it computes `max_request`: for each operation, the
largest frame, decoded size and nesting of any message it carries
towards each side, a request and its reply, and for an open every push
and request of the socket protocol, each rounded up to a power of two.
A receiver's floor for a limit is the largest over the operations it
takes part in. Each floor is a constant of the generated modules, and
the generator fails the build when a floor passes the limit's default,
so the schema cannot grow a reply that a domain with default limits
would drop. Paging the `interfaces` reply was the other way to keep it
small; it would add a continuation to the grant and a loop to every
caller, for a reply the default `max_frame`, 1 MiB, already carries.
Each floor is checked where a receiver's limits are known:

* **a client's, in the client, before anything is sent.** `erx_inet`,
  the one path to the grant, compares the floors of the operation it is
  asked for with its own runtime's `max_frame`, `max_message_heap` and
  `funnel_depth`, as `erx:limits/0` reports them
  ([design-domains.md](design-domains.md#erlang-interface)), before it
  calls the grant; outside erXos, with `Origin` `local`, no frame
  crosses a funnel and there is nothing to compare. An operation whose
  floor the client does not meet is answered `{error, enobufs}` by
  `erx_inet` itself, with no remote call, and the first such answer
  for each operation writes one line to the domain's log naming the
  operation, the limit, its value and the floor; the operations whose
  floors the client meets work as ever. An open is one of those
  operations, and its floors cover every push and request of the
  socket it opens, so no socket exists whose pushes its own funnel
  would drop. So a domain configured below a floor fails at its first
  use of what it cannot carry, a socket's open or an `interfaces`
  call, loudly and with the reason in its log, and never meets the
  silent hang of a dropped push or reply, the refusal's own reply
  included, since there is none. The grant checks nothing for the
  client: a client that skips the check drops only its own replies;
* **the network domain's own, in the system manifest.** Its
  `max_frame`, `max_message_heap` and `funnel_depth`, and the
  `max_request` its grants name, are fields of its specification, and
  the manifest's build check compares each with its floor, so a network
  domain that would drop a correct socket process's frame does not
  build.

`erx_sock_admit` refuses a push longer than a piece, or of more than 64
binaries, as it refuses one past the credit, so a push of another size
aborts its socket rather than being taken.

A connection holds no byte beyond its send buffer's size, since the
send credit it grants is room in it, so its buffer reservation at the
grant covers everything its socket process can send it. A datagram
socket's send is a call, a lane round trip per datagram, which the watch
list holds ([todo-performance.md](todo-performance.md)).

#### Requests in flight

A socket process has at most 64 calls in flight to its socket, the
socket protocol's limit; a connection's bytes are not calls and take no
place. A call is in flight once the outlet has queued it for the lane.
A call that would be the 65th, or that the outlet refuses, waits in the
socket process, in arrival order, until a reply frees a place and the
lane takes it: the core holds the waiting calls, as stock's port holds a
caller while it is busy, and drops none. So the waiting-call queue, not
the count of places, is what holds calls back from a lane that is not
drained, and a reply that frees a place early, forged or not, queues
nothing more for that lane. Two kinds of call also wait behind their own kind,
whatever the count:

* a `send` waits for the `send` before it to be answered, so the bytes
  of two sends never interleave, as stock's driver takes one send at a
  time; it counts its deadline from its own call
  (**Send credit**, above);
* a passive `recv` waits for the `recv` before it, as `gen_tcp_socket`
  postpones a second one (`gen_tcp_socket.erl:2100-2105`), and a `recv`
  on an active socket answers `{error, einval}`, as there.

Every other call, `shutdown` among them, goes out as soon as it has a
place and the lane takes it, so it never waits behind a send that waits for send
credit. A call that waited for a place takes its timeout from the moment
its request is sent, not from the call. Of the calls that carry a
timeout only `accept` can wait so, on a listener with more than 64
concurrent acceptors; this difference from stock has a test. When
the socket ends, every waiting call is answered as stock's closed socket
answers it.

The socket enforces the same limits on what it takes: past 64 calls in
flight it refuses with `{error, badarg}`, and a connection aborts on
bytes past its send credit (**Send credit**, above), both of which only
a socket process that breaks the
protocol meets. What a client domain can make one socket hold is
therefore 64 calls within the schema's bounds and, for a connection, the
bytes of its send credit, which its send buffer's reservation covers.

### Options

| Options | Where they act |
| --- | --- |
| `nodelay`, `keepalive`, `linger`, `sndbuf`, `recbuf`, `tos`, `tclass`, `priority`, `reuseaddr`, `reuseport`, `ipv6_v6only`, `high_watermark`, `low_watermark`, `{congestion, Name}`, `{loss, Name}`, the `raw` options FreeBSD's `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, `TCP_KEEPCNT` and `TCP_MAXSEG` map to | the socket's state, read by its step |
| `active`, `mode`, `binary`, `list`, `header`, `packet`, `packet_size`, `line_delimiter`, `deliver`, `buffer`, `exit_on_close`, `show_econnreset`, `send_timeout`, `send_timeout_close` | the socket process: how it presents data to its owner, its credit, and how long a `send` waits for send credit |
| `broadcast`, `multicast_*`, `add_membership`, `drop_membership` | `broadcast` acts; the multicast options act through `erx_mcast` ([Scope](#scope)) |
| `fd`, `netns`, `bind_to_device`, other `raw` options | `{error, enotsup}` |

`inet:setopts/2` with options of both kinds sends the socket's to the
socket and applies the socket process's own only once the socket has
accepted the rest, so a refused `setopts` changes nothing;
`inet:getopts/2` answers the socket process's own and asks the socket
for the rest, in the order asked.

### The `socket` and `net` modules

OTP's `socket` module calls the `prim_socket` NIF, which erXos drops. An
Erlang `prim_socket` takes its place and speaks the same socket protocol
to the network service, a process of it in the client's domain standing
as each socket's socket process, so `socket` and its `gen_tcp_socket`
backend work over the same connection, listener and datagram processes
as `gen_tcp` and `gen_udp`; `net`'s interface and host calls are answered
by the grant. `gen_tcp`, `gen_udp`, `ssl`, `ssh` and distribution do not
use `socket`, so it comes after them
([Decisions](#decisions), 5), and plan.md schedules it.

### Name resolution

`inet_res`, OTP's DNS resolver in Erlang, runs over `gen_udp` in each
domain, through `erx`, the default backend. The grant's `resolver`
operation returns the name servers and search list the network domain
learnt from its static configuration, DHCP (options 6 and 15) or router
advertisements (RFC 8106), within resolv.conf's limits of three name
servers and six domains, and only reads them; `watch_resolver` returns
the same answer and makes its caller the grant's one subscriber, which
`{erx_net_resolver, Grant, Answer}` reaches after each change, so a
reader never displaces the subscriber. In each domain,
`erx_net_client`'s resolver loader, `erx_inet`, watches at start and
again after the grant ends, checks each answer as input from another
domain, and loads it into `inet_db`: the name servers and search list
replace inet_db's, `dns` joins the lookup methods after the hosts file,
and the answer takes the place of resolv.conf, which a domain does not
have. A search domain is checked by the DHCP client's rules: labels of
letters, digits and hyphens that begin and end with a letter or digit
(`res_hnok`), each of 1 to 63 bytes, at most 253 bytes in all, one
trailing dot allowed and dropped; stricter than `res_hnok`, which also
takes an empty label, since `inet_dns` cannot encode one and would fail
the caller's query. A domain that fails the check is dropped and the
rest of the answer loaded. Query IDs are the kernel's random bytes, not
`inet_db`'s counter, though erXos releases no `crypto`
([design-runtime.md](design-runtime.md), edit 63), so an off-path host
must guess both the ID and the source port (RFC 5452). The `host`
command ([design-shell.md](design-shell.md)) asks the same name servers,
or the one it is named.

The check of each answer, the reply to `watch_resolver` through
`erx_inet:call/1` and each change message alike, is `erx_sock_admit`'s,
as for every answer of the grant
([Untrusted input](#untrusted-input)).

### Distribution to other machines

An exposed domain reaches other machines under its own node name over
OTP's own TCP distribution carrier, beside the `erx` carrier that serves
names at this machine's host name
([design-runtime.md](design-runtime.md#connections-in-erts)). Stock
nodes find a node's port through its host's port mapper, epmd. The
network domain runs one, `erx_epmd`, speaking epmd's protocol on port
4369:

* An exposed domain registers through its grant, with the `epmd_module`
  OTP lets a node configure: `register_node` sends the grant
  `{register_node, Port}`, and the grant registers the domain's own node
  name with the port only if the domain holds that listening port. No
  domain registers a name that is not its own.
* `PORT_PLEASE2_REQ` from any peer is answered for registered names;
  `NAMES_REQ` lists only registered names. A registration ends with the
  domain's listening socket, its grant or the domain.
* `ALIVE2_REQ` arriving from the network is refused: registration comes
  only through grants.

The carrier's handshake refuses a remote node that claims a name at this
machine's host name ([design.md](design.md#networking)). A release build
allows only OTP's TLS carrier, `inet_tls_dist`, which authenticates both
nodes by certificate and encrypts; the domain's keys stay in the vault
and are used through a key facet. A development build allows the plain
TCP carrier as well, whose MD5 challenge over a shared cookie
authenticates weakly and encrypts nothing ([Decisions](#decisions), 4).

## The interface towards POSIX programs

A program's socket descriptor names an open of its handler's table, as a
file descriptor does, and the open names the socket's **open-file
description**, a process of the session, as a file's description is
([design-programs.md](design-programs.md#descriptors-and-files)). The
description is the socket's owner at the network service, and the
protocol offers it what POSIX needs:

* `{watch, Events}`: the socket sends one `{ready, S, Events}` when it is
  readable, writable, acceptable or has an error, which the description
  passes on as `{ready, Open, Events}` to the program that asked;
* `{recv_nb, Max}` and `{send_nb, Data}`: they never wait, and answer
  `{error, eagain}` when POSIX's nonblocking call would; a program's
  blocking read is a watch followed by a nonblocking read, so no request
  waits in the network domain;
* `accept_nb`, `getsockopt` and `setsockopt` in FreeBSD's names, mapped to
  the same options.

A socket belongs to its grant's domain, the session's, not to one
program, and lives until its description closes it or exits. Programs of
one session share a socket as they share any open-file description: a
spawn, a `fork`, `SCM_RIGHTS` between programs of the session and an
`exec` give or keep opens that name the same description, and the
network service sees nothing of them. The description closes the socket
when the last open naming it closes. Moving a socket to another domain
is not offered, since a socket acts for its grant's domain alone.

## Untrusted input

Every packet is hostile. The rules, and where each is enforced:

| Rule | Where |
| --- | --- |
| Every length read from a header is checked against the enclosing layer before use; trailing bytes are cut at the length the header states | each `*_wire` decoder; fuzz targets |
| Decoders are total: `{ok, ...}` or `{error, Reason}`, never an exception | fuzz targets fail on any exception |
| No field a checksum covers is read before the checksum is checked, except the fields that choose a frame's destination, which only the lookup reads; a segment, datagram or ICMP record is made only by its decoder, which checks the checksum first | `erx_net_input`, the `*_wire` decoders; a build check that only the decoders make those records; tests that the decoders check the sum first: the fuzz targets' wrong-sum inputs and the interface's gate |
| No checksum claim from a device or a host's kernel is believed: a frame's network sum is computed by `erx_net`'s own C over the bytes its binary holds, each word loaded once, and `VIRTIO_NET_F_GUEST_CSUM` is never negotiated | `erx_inet_copy_sum` and its callers, `erx_virtio_net`'s wanted features; the interface's gate with a lying sum ([Checksums in the copy](#checksums-in-the-copy)) |
| No atom is made from packet data; unknown protocol values stay integers | the codecs; a build check fails on `binary_to_atom`, `list_to_atom` and `binary_to_term` in `erx_net` |
| Sequence-space conversion happens only in `erx_tcp_seq` | a chokepoint check fails on 2^31, 2^32 - 1 or 2^32 written as an integer literal in any base, or a left shift by a literal 31 or 32, in any other TCP module |
| Half-open connections live only in the bounded syncache; overflow is answered statelessly with cookies | `erx_tcp_syncache` |
| A RST resets only at exactly `last_ack_sent`; a SYN in a synchronized state and an out-of-range ACK get rate-limited challenge ACKs | RFC 5961 stages |
| IP identification values reveal nothing: zero on atomic IPv4 datagrams, random otherwise and on IPv6 fragments | `erx_ip4`, `erx_ip6` |
| Random values (identifications, ephemeral ports, flow labels, nonces, delays, limit jitter) come from the owner's `erx_net_rand` generator, keyed from the kernel's entropy generator through `erx_net_clock`; no module of `erx_net` calls `rand`, and only the portable `erx_bytes` calls `crypto` | `erx_net_rand`; a build check |
| Initial sequence numbers are unpredictable (RFC 6528); timestamp clocks are offset per connection | `erx_tcp_isn` |
| ICMP reports act only when their quoted sequence number is in flight | `erx_tcp_icmp` (RFC 5927) |
| Reassembly queues, both IP and TCP, have caps on count, bytes and lifetime; held payloads count at the size they keep alive | reassembly modules |
| Neighbour messages are accepted only by RFC 4861's rules (hop limit 255) and FreeBSD's ARP rules; tables and held packets have bounds | `erx_arp`, `erx_nd6`, `erx_lltable` |
| Router, prefix and redirect entries have per-interface bounds; new entries past them are ignored, listed ones are never evicted | `erx_nd6_rtr`, `erx_net_route` |
| DHCP replies reach only the interface's DHCP client, and only for its outstanding transaction | the interface's DHCP path |
| ICMP errors, RSTs to closed ports and echo replies are rate-limited; no reply to a broadcast or multicast | the interface's limiters |
| Traffic that names no socket spends the interface's budget | the ingress limiter, below |
| Packets queued for any process are bounded | credits |
| Text from packets reaches logs and the inspector only through the sink's escaping function | `erx_log` |
| Ring fields a netmap port shares are read once per call and checked before a byte is copied: offsets and sizes at registration, `tail` and each slot's buffer index and length at each call; every copy lies inside one buffer of the mapping | `erx_netmap_ring`, its tests and fuzz target ([The netmap transport](#the-netmap-transport)) |
| What a virtio device wrote into a receive buffer is cut by its size alone: the device header is skipped unread, a frame shorter than an Ethernet header is `malformed` and one longer than the MTU and its Ethernet header `too_long` | `erx_virtio_net:frames/2` and its fuzz target, `tools/fuzz/erx_virtio_net_frame.rb` |
| A socket takes requests only from its one socket process, and a connection takes bytes only within the send credit it granted | the socket's check of `ReplyTo` after `erx_net_admit`; the connection's count of the send credit outstanding |
| A socket process takes a message from its socket only when it passes `erx_sock_admit`: the origin its grant was found with, its own socket's pid, a shape of the socket protocol, data within the credit outstanding and at most a piece in at most 64 binaries, send credit a positive count that keeps the credit outstanding within 2 MiB, a datagram's address and port well formed, an end reason from the closed list, a reply under an `N` in flight in the reply shape its operation declares | `erx_sock_admit`; its fuzz target |
| No term the network domain chose reaches program code: every push and every answer of the grant passes `erx_sock_admit`, and what an owner or a caller receives is built from its checked parts | `erx_sock_admit`; `erx_gen_tcp_core`, `erx_gen_udp_core`; `erx_inet:call/1`, the one path to the grant |
| A network domain that stops draining its lane makes a client queue for it no more than it would for any peer: the busy limit, plus one frame per sending process | `erx_sock_out`, the socket process's one way to start and to send, which spawns it with `{async_dist, false}` and refuses rather than queue past the busy limit; the build checks that no other site in the socket process's modules sends, links, monitors, calls or sets `async_dist` |
| What a client keeps because of a hostile network domain is bounded by what it granted: nothing before a socket process holds its socket, its target while it is held, during a transfer included, and of each send, the bytes the queue bound counts | the first contact, before which a message from the network domain ends the opening; the transfer's held presentation; every piece a binary of its own size |
| The trusted base parses no network traffic | the manifest check's property 15 and the mint's refusal of the system domain as a grantee |

**A socket process's trust in its socket.** A push from the network
domain is a message from another domain, and untrusted as every such
message is. `erx_sock_admit` is generated from the operation schema's
reply types, as `erx_net_admit` is from its requests, and hand-written
with the generated module's signature until the generator exists
([Decisions](#decisions), 10). A message from the socket that fails it,
a shape outside the protocol, data past the credit or longer than a
piece, or a reply to no request, aborts the socket: the socket process
sends `close`, presents what it held and then the end as `{error,
econnaborted}`, and logs one line naming the socket and the check that
failed, never the message; it never raises. So the network domain can
do to a client what a network can: send it bytes within its credit, end
its sockets, answer its requests, withhold send credit, as a peer
that stops reading holds a sender back, so a `send` waits until its
`send_timeout`, and stop draining its lane, as a network that stops
carrying packets holds a sender's bytes. It cannot grow what a socket
process holds past its credit, make the client queue more for its lane
than the busy limit and a frame per sending process, put a term of its
choosing in an owner's mailbox, or stop a socket process from running
(**The socket process never suspends**, in
[The socket process](#the-socket-process)).

**What the network domain can make a socket process hold.** Each kind
of message it may send has its own bound:

* pushes, the credit: a push past the credit outstanding aborts the
  socket, so the bytes a socket process holds never pass its target;
* replies, the calls in flight: at most 64, each in its operation's
  declared shape, and a reply under no `N` in flight aborts the socket;
* send credit, nothing: a grant lets the socket process send sooner
  only the bytes its callers gave it, and only as the lane takes them,
  and a grant that takes the credit outstanding past 2 MiB aborts the
  socket;
* a lane it stops draining, what waits for that lane in the client's
  runtime: the busy limit, 1 MiB, for the whole client, and one frame
  past it for each process caught sending, a piece and its header for a
  socket process (**What waits for an undrained lane**, in
  [The socket process](#the-socket-process)). The rest waits where it
  already waits: the bytes in their callers' sends, the calls in the
  waiting-call queue, and receive credit as one count per socket,
  however much the network domain pushes and the owner consumes. A
  piece still queued when its send is answered keeps alive only its own
  bytes, since the socket process copies a send's tail when its binary
  holds more;
* the end, once;
* anything else, a message to a socket that has ended or one of no
  protocol, is dropped and counted as the socket process takes it.

What the socket process has not yet taken is bounded by its runtime's
queue quota (edit 15 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos),
which plan.md's RT8 builds): past it the funnel leaves the network
domain's next frame in its lane, which holds back only what the network
domain sends that client. A correct network domain meets the quota only
when a socket process falls behind its pushes, and then the lane pauses
until it catches up, which loses nothing; since no process waits in
`receive` at its quota ([design-domains.md](design-domains.md#flow-control)),
a pause cannot deadlock. A client domain's processes have a quota only
where its runtime sets `-erx queue_quota`, and which domains do is an
open decision ([Open decisions](#open-decisions), 1). Until RT8, the funnel
delivers every authorised frame whatever its target already holds, so a
flood that outruns a socket process grows its queue with nothing to stop
it but the client domain's budget, the gap of the stopgap funnel that
`TODO.md` records.

**Answers from the grant.** The grant's reply to a call reaches its
caller with the envelope already off, since `gen` owns call replies
([design-domains.md](design-domains.md#the-peer), D18), so it would reach
program code as the network domain chose it. Every call to the grant
therefore goes through `erx_inet:call/1`, which finds the grant,
refuses with `{error, enobufs}` an operation whose floors its own
runtime does not meet ([Message sizes](#message-sizes)), calls the
grant, and passes the answer through `erx_sock_admit:answer/3`, against the
reply type the schema declares for that operation and the grant's node,
and returns what it rebuilt from the checked parts. It waits with the
timeout `infinity`, as every call of the stack does
([Build checks](#build-checks)): the call's monitor ends the wait when
the grant ends, an open's own `Timeout` is the socket's to enforce, and
a network domain that never answers holds only its caller, as a network
that never answers would. The resolver loader's `watch_resolver` is such
a call, and the loader tries again only when it finds no grant or the
grant ends. What it admits:

* an open's `{ok, Socket}`: `Socket` a pid of the grant's node;
* `interfaces`: at most 64 interfaces, each rebuilt from the keys
  `ifconfig` shows and nothing else: a name of 1 to 15 bytes, FreeBSD's
  `IFNAMSIZ`, of letters, digits, `.`, `-` and `_`; a six-byte
  link-layer address; an MTU; the link state; the configuration; and at
  most 64 well-formed addresses with their prefix lengths;
* `hostname`: a name of labels as FreeBSD's `res_hnok` admits;
* `resolver` and `watch_resolver`: a map of at most three IPv4 name
  servers on port 53 and at most six search domains, the check
  `erx_inet:resolver_config/1` makes; each search domain is checked
  alone, and one that fails is dropped and the rest of the answer kept
  ([Name resolution](#name-resolution));
* an error: a reason from the operation's closed list.

The grant's change messages to `erx_inet`'s loader,
`{erx_net_resolver, Grant, Answer}`, arrive in their envelope and pass
the same module, against the grant's origin and the `resolver` reply
type. `erx_inet` exports no grant pid, so no module of `erx_net_client`
reaches the grant another way. An answer that fails the check is the
call's `{error, badarg}` and one line in the log naming the operation
and the check, never the term; a change message that fails it is
dropped, and the loaded answer stays.

**The ingress limiter.** Owned traffic, a frame that demultiplexes to a
socket, is bounded by that socket's credit, and what the socket spends on
it is charged to its grant. Unowned traffic, everything the interface
process itself must answer or hold (SYNs, ARP and neighbour requests,
echo requests, fragments, DHCP replies, RSTs to send), spends a token
bucket of the interface, in frames per second with a burst. Past it,
unowned frames are dropped and counted while owned frames and the
replies the interface awaits (ARP and neighbour advertisements for
entries it is resolving) still pass. Established connections and address
resolution therefore keep making progress under a flood of
new-connection traffic. The bucket's rate and burst are settled by the
flood measurements of plan.md's network gates.

**What a flood costs the interface.** Every frame, owned or unowned,
costs the interface process a header decode and one lookup before it is
kept or dropped, and only a frame that holds room costs more: its check,
a constant with the network sum, and its decode
([Receiving](#receiving)). The pipe is the exception: its frames come
without a sum, and the merge sums each one before classification, so
there every frame of a flood costs a read of its bytes, whatever room it
finds. A flood of frames with valid checksums aimed
at one client's established connection therefore costs the interface
process no more per frame than any flood of minimum-size frames: once
the connection's credit is full, each further frame is decoded, looked
up and dropped, and what the connection takes, at the rate its grant's
share lets it take it, is charged to that grant. The interface's own
cost per frame is spent on the network domain's grant, the same whoever
the frame names. A frame that holds room and fails its checksum returns
its room, so the checks of such frames are bounded by link capacity
alone, not by credit or the bucket; with a network sum each check costs
a constant ([Checksums in the copy](#checksums-in-the-copy)). Whether one interface process keeps up with
minimum-size frames at line rate is what the network gates measure;
where it cannot, the driver's credit fills and the driver drops frames
for every client alike ([Residuals](#residuals)).

### Residuals

Each of these is a known gap, with the reason it stays:

* **One interface process is a ceiling for all clients.** A line-rate
  flood that the interface process cannot decode as fast as it arrives
  makes the driver drop frames for every client, whatever they are. The
  cost per frame dropped for want of room is a header decode and a
  lookup, kept small by [Receiving](#receiving)'s order, where the
  transport's copy gives each frame its network sum. Over the pipe, whose
  frames come without one, the merge sums every frame before it is
  classified, so each frame costs a read of its bytes, kept or dropped;
  the pipe is a host transport for development and tests, never
  erXos's medium, so the cost stays there. One interface process per receive
  queue, on devices that hash flows to several queues ([Scope](#scope)),
  divides the work. A bound per client here would need a classifier ahead
  of the interface process, which is what the interface process is.
* **Resolution is shared between clients.** A client that sends to many
  unresolved on-link addresses makes its interface hold up to 16 packets
  for each, send a request for each, and, once the neighbour table is
  full, evict the oldest entries in resolution, other clients' among
  them; the sender credit bounds the rate of its hand-overs and the
  table bounds what is held, but nothing bounds one client's share. A
  per-grant count of the entries each grant's packets started, with a
  cap past which its hand-overs are dropped as lost frames, would bound
  it; FreeBSD has no such bound, and the cost is a grant tag on every
  hand-over and entry. `TODO.md` records it.
* **Stranded credit.** A sender killed between reserving credit and
  sending strands at most one hand-over's units on the receiver's
  counter until the receiver restarts
  ([Credited queues](#credited-queues)). Only a fault or a test kills a
  connection or an interface process; a counter that never drains would
  need the receiver to reconcile against senders it cannot see.
* **The interface's own frames have no reserved transmit share.** ARP
  and neighbour-discovery answers, RSTs and SYN-ACKs take the driver's
  transmit credit as clients' data does, so senders that keep it full
  delay resolution and handshakes until it drains. FreeBSD's send queue
  has no reserved share either; a small share of the transmit credit for
  the interface's own frames would bound it, and `TODO.md` records it.
* **A network domain decides whether an open succeeds and when.** The
  `link` right a socket process exports is held by the network domain,
  not by one process of it, so any of its processes may link to a
  socket process and end its opening, and `connect`'s and `accept`'s
  deadlines run on the stack's clock, so a network domain that never
  answers holds the opener for as long as it waits. Neither makes the
  client hold anything: the opening keeps nothing from the network
  domain, and the opener waits as on any facet that does not answer.
  The network domain serves every socket it opens, so it can deny any
  of them service whatever the client checks; an export to one process
  of a domain would bound who may link, not what the domain may do.

## Concurrency and failure

### Ordering

Segments of one connection pass through one interface process and one
mailbox, in arrival order, and the connection steps through them one at
a time. A socket's replies and pushes to its socket process travel on one
lane in order with its exit, and the socket process alone presents them
to the owner and answers the owner's calls, so the owner sees them in the
order the socket process made them; `inet:setopts(S, [{active, false}])`
and `controlling_process` are local to the owner's domain and need
nothing from the network domain to keep that order
([The socket process](#the-socket-process)). Two binders of one key are
ordered by `ets:insert_new/2`. The interface and the driver never send
to another domain, so no client can stall packet input, and a socket's
pushes are bounded by its socket process's credit, so a client that
stops reading stalls only its own sockets.

### What fails and what survives

| Failure | Seen by | What survives | What ends |
| --- | --- | --- | --- |
| a frame that a step cannot handle (a bug: the step raises) | the interface process, which counts and logs the event | the interface's state from before the frame; every connection | the frame |
| the interface process crashes outside a step | its link supervisor; `erx_net_tables`, which deletes the rows that name it | the driver, every connection | the interface's soft state: neighbours, reassembly, half-open handshakes; its published rows, and with its `erx_dhcp4` a DHCP lease, which the restarted client asks for again |
| the driver crashes, or the device breaks its queue | its link supervisor, which ends the link; the interfaces supervisor starts it again, at most once a second while the device keeps failing | every connection; their unacknowledged data is retransmitted | the device's queued frames; the interface process restarts after the driver's reset |
| the driver has no attached interface, between an interface's end and its restart | the driver, which monitors the attached interface | everything | the frames received meanwhile, dropped and counted as `detached` |
| a device's queue is full, or a transport refuses a frame | the driver | everything | nothing while the backlog has room, which the transmit credit bounds; past it senders' hand-overs are refused and counted where they are made |
| a call on a netmap port fails (its registration, a sync or an arm), or its ring breaks | the netmap transport, which ends the driver, whose link the interfaces supervisor starts again | every connection | the link's soft state, as a driver crash; a port that stays unregistrable restarts the link at most once a second ([Ending](#the-driver), [The netmap transport](#the-netmap-transport)) |
| a pipe's far end goes away | the pipe: a `process` end by its monitor, and the tap transport by an error of its descriptor, each ending the driver, whose link the interfaces supervisor starts again; a `udp` end only as refused sends | every connection | the link's soft state, as a driver crash; a far end that stays away restarts the link once a second; TCP retransmits once the far end returns |
| a socket's step raises (a bug) | the socket, which ends itself from its state before the event, then exits with the exception; its grant deletes its entries and logs the exit | everything else | the socket: a connection sends a RST and pushes `{error, econnaborted}`, which its socket process presents as `{tcp_error, S, econnaborted}` and `{tcp_closed, S}`, or as the error of a waiting call |
| a socket is killed or crashes outside a step | its grant, which deletes its entries; its socket process, by their link | everything else | the socket: the peer times out or meets a RST later; the socket process presents the end as `{error, econnaborted}` |
| a socket's owner exits | its socket process, which monitors it and stops | everything else | the socket process; its socket, by their link, closes as `close/1` does: a connection sends FIN, or RST if `linger` is zero |
| a socket process crashes or is killed | its socket, by their link | everything else | the socket, closed as on its owner's exit; the owner's next call gets `{error, closed}`, and in active mode the owner is told nothing, as with stock's `gen_tcp_socket` |
| a socket process's step raises (a bug) | the socket process, which presents the end as `{error, econnaborted}` from its state before the event, then exits with the exception | everything else | the socket process and, by their link, its socket |
| a push breaks the socket protocol | the socket process, through `erx_sock_admit` | everything else | the socket, aborted ([Untrusted input](#untrusted-input)) |
| the grant ends (revocation, its domain ends) | its sockets, by the link: each connection sends RST and exits | other grants | the domain's sockets and registrations; each socket process presents its socket's end |
| a client domain ends | the network domain, by its sockets' links and the grant's end | other domains | that domain's sockets, each with a RST |
| a client stops reading | its socket processes, whose credit runs out | other sockets and domains | nothing: that client's windows close, as TCP's do |
| a peer stops reading | its connection, whose send buffer stays full, so its send credit stops | other sockets and domains; the owner's other calls on the socket | nothing: a `send` waits in the socket process, as a blocking `send` waits on FreeBSD, until its `send_timeout`, and is then answered with the rest it did not send |
| the network domain stops draining a client's lane | that client's frames to the network domain, which wait in the client's runtime up to the busy limit and a frame per sending process; past it the outlet refuses | other domains; the client's socket processes, which never suspend, so their timeouts, closes, owners' exits and pushes go on; a process of the client that calls the grant waits, as a call to any stalled domain waits | nothing the network domain did not already hold: sends that fit their credit are answered `ok` once queued, the rest wait in their socket processes and meet their `send_timeout`, and the exits of socket processes that stop reach their sockets once the lane drains |
| a socket died and its entries are not yet deleted | nobody: `classify/2` finds the entry and the frame's message goes to a dead pid | everything else | the frames that arrive before its grant deletes the entries, as if dropped; a TCP peer retransmits and meets a RST once the entry is gone |
| the configuration changed during a batch or between output passes | the next batch's view, the next pass's path | everything | nothing: frames classified or framed against the old copy behave as under FreeBSD's epoch, which lets a lookup finish against the table it started on |
| a next hop does not answer resolution | the interface, which holds up to 16 packets for it | everything else | its held packets: dropped after 20 s for ARP, or the oldest returned as an ICMPv6 address-unreachable to the stack's own socket for neighbour discovery ([Framing](#framing)) |
| the interface's MTU drops under a connection | the connection's next output pass, through the context's MTU | the connection | nothing: on IPv4 the next segment under don't-fragment that would not fit lowers `t_maxseg` and is sized again ([Output](#output)); on IPv6 a segment over the MTU is fragmented, as FreeBSD sends it |
| a route goes away under a connection | the connection's next output pass | the connection, which sends nothing until a route returns | the connection, at its retransmission timeout: with `ehostunreach` once it has received a SYN, with `etimedout` in SYN-SENT |
| `erx_net_tables` or a top-level child exceeds its restart intensity | the network domain's supervisor | nothing in the domain | every socket; owners' next calls get `{error, closed}` |

A raising step is caught in three places, and in each the step's purity
makes the handling complete: the exception leaves the state exactly as
it was before the event. The interface process drops the frame, keeps
its state and goes on, since a frame is its unit of work and its state
serves many flows; a merge that raises, which only a bug can make once
the driver cuts every batch to the merge's limit, drops its batch the
same way, the batch's receive credit already taken
([design-network-fastpath.md](design-network-fastpath.md#concurrency-and-failure)). A socket, and a socket process in the owner's domain,
ends itself properly from its intact state, as the table says, and then
exits with the exception as its reason, since its state is one flow's
and a bug in it is not worth keeping alive. All three
record the exception and the event, a frame's length and its first 128
bytes escaped, in the kernel log, and count it. The record keeps the
stack trace with each frame's arguments replaced by their count, and a
socket's exit reason is the exception's class and reason alone, so a
`function_clause` never carries the control block into a log; a
socket's `format_status` likewise leaves out its buffers, its
reassembly queue and its generator, and a socket process's what it
holds, so `sys:get_status` shows neither a
flow's payload nor the generator its sequence numbers and ports come
from. A request reaches the step only after the admission path has
checked its shape against the schema, so a malformed request is
refused there with `{error, badarg}`, as a facet refuses, and never
raises in the step.
No other exception is
caught. The fuzz targets and the explorer fail on any exception, so in
tested code neither path runs.

### The network domain's own end

A network domain killed under load restarts as any configured domain
does. Its connections end with it: their peers see silence and time out,
or receive RSTs to later segments; clients see their sockets close. No
client domain is affected beyond its sockets.

## Refusals and error results

| Result | When |
| --- | --- |
| `{error, eacces}` | the domain holds no `net` grant; the grant does not allow the port, address or `listen` |
| `{error, emfile}` | the grant's `sockets` limit is reached |
| `{error, enobufs}` | a buffer reservation exceeds the grant's `buffers` limit; every call of an operation, a socket's open or `interfaces` among them, whose floor for `max_frame`, `max_message_heap` or `funnel_depth` the caller's own runtime is below, answered by the client side before any request is sent ([Message sizes](#message-sizes)) |
| `{error, eaddrinuse}` | the key is held, under FreeBSD's reuse rules |
| `{error, eaddrnotavail}` | the local address is not the machine's, no usable source address leaves through the route's interface, or no ephemeral port is free |
| `{error, econnrefused}` | a RST answered the SYN |
| `{error, etimedout}` | connection setup or retransmission exceeded FreeBSD's limits |
| `{error, enetunreach}` | `connect`, or a datagram sent without a local address, finds no route (`in_pcbladdr`) |
| `{error, ehostunreach}` | a datagram's route has gone (`ip_output`); a synchronized connection's soft error at its timeout; an unreachable report in SYN-SENT |
| `{error, econnreset}` | a RST in a synchronized state, under `show_econnreset` as on stock; under `show_econnreset`, the first `send` waiting when a reset or an abort ends the socket or, when none waits, the first `send` after it, and the first `send` that meets its write side shut, as the socket backend curates them |
| `{error, econnaborted}` | the socket protocol broken either way, and the socket aborted: by the connection, on bytes past its send credit or after its write side's `shutdown` or `close`; by the socket process, on a push that fails `erx_sock_admit`, a grant past 2 MiB among them; a socket that exits without a last push; a connection step that raises |
| `{error, enoprotoopt}` | an ICMP parameter problem answered the SYN, as FreeBSD's `icmp_errmap` maps it |
| `{error, closed}` | the socket is closed, as on stock; a `recv` that the peer's FIN leaves short, as on stock; a `send` waiting at `close/1`; every `send` waiting behind the one the socket's end or a shut write side is shown to; without `show_econnreset`, each `send` the `econnreset` row lists |
| `{error, enotconn}` | a `recv` after one the peer's FIN left short, or one answered the socket's error, as on stock |
| `{error, timeout}` | an Erlang call's own timeout, as on stock; a `send` still waiting at its `send_timeout` under `send_timeout_close`, which then closes the socket |
| `{error, {timeout, Rest}}` | a `send` still waiting at its `send_timeout` without `send_timeout_close`; `Rest` is the bytes it did not send, as the socket backend returns them |
| `{error, emsgsize}` | a datagram larger than IP allows, or a packet over `packet_size` |
| `{error, einval}` | an option value out of range; a socket used from a domain other than its socket process's |
| `{error, not_owner}` | `controlling_process/2` called by a process other than the owner, as on stock |
| `{error, enotsup}` | `fd`, `netns`, `bind_to_device`, unknown `raw` options, SCTP |
| `{error, badarg}` | a request the admission path refuses: wrong origin, schema or size, or past the socket protocol's requests in flight; a grant's answer that fails `erx_sock_admit`, an open's socket of another node among them; `controlling_process/2` to a process of another domain, as stock refuses one of another node |

An interface that cannot start is refused by its driver's `init`, and its
link supervisor fails to start with the reason: `{lladdr, Addr}` for a
pipe's address that is not a locally administered unicast address,
`{mtu, N}` for a pipe's MTU outside 1,280 to 9,000. A virtio device the
transport cannot drive, an empty transport or one the device NIF
refuses, is no interface rather than a fault: its `init` answers
`ignore`, the link supervisor starts nothing and answers `ignore` too,
and the stack starts without it, as the block driver does without a
disk; any refusal but an empty transport's is one line in the kernel log
([The driver](#the-driver)). A netmap transport refuses only what
restarting cannot fix, its configuration and its build (`{netmap,
unavailable}`, `{netmap, {api, Kernel, Built}}`, `{mtu, N}` over the
port's buffers), and takes a port it cannot register as its medium
ending, so its link is held and restarted, at most once a second
([Ending](#the-driver), [The netmap transport](#the-netmap-transport)).
The application itself refuses to start with `{seam, Key, Module}` when a configuration
key names a seam module the build does not hold
([Two places, four seams](#two-places-four-seams)).

## Where C is used, and what is measured

C does per-byte work, and the per-frame work that rides on a pass over
the bytes, as the design requires ([design.md](design.md#decisions)).

* **The Internet checksum,** `erx_bytes:inet_csum/2`, already among the
  per-byte primitives, over an iolist so headers and payload are summed
  without being joined. It uses the CPU's checksum-friendly instructions
  where the architecture layer has them, with portable C as their oracle.
  On the paths that carry segments it is not a pass of its own: the copy
  between a device's buffer and a binary computes it, through
  `erx_inet_copy_sum` of the same core, and a device that offers
  checksum offload on transmit may finish it instead, an extension
  ([Checksums in the copy](#checksums-in-the-copy), [Scope](#scope)).
  `inet_csum/2` stays for transports that copy nothing in C, for
  headers, and as the oracle of both.
* **SipHash-2-4,** a primitive this design adds,
  `erx_bytes:siphash24/2`, taking a 16-byte key and an iolist, for
  initial sequence numbers, timestamp offsets and SYN cookies, the hash
  FreeBSD uses for all three, and for the stream of `erx_net_rand`. A
  hash is per-byte work by the design's own
  list, and a SYN flood makes this one per-packet: in Erlang its 64-bit
  arithmetic would leave small integers on every round. It also keeps
  OpenSSL out of the domain that parses hostile packets. RFC 7217's
  HMAC-SHA-256 is computed by the vault, which holds its key
  ([IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)).
* **The entropy source,** `erx_bytes:entropy/1`: it returns up to 256
  bytes from `erx_entropy_read` and raises when the read fails, never
  substituting other bytes
  ([design-runtime.md](design-runtime.md#per-byte-primitives)). It is
  not per-byte work but Erlang's entry to the kernel's generator in a
  domain without OpenSSL, as the network domain is
  ([design.md](design.md#decisions)), and the stack calls it, through
  `erx_net_clock`, only when an owner starts and when
  `erx_net_tables` draws or rotates a secret
  ([One owner, one step](#one-owner-one-step)).

* **The cut and the merge,** `erx_tcp_cut.c` in each transport's copy
  and `erx_bytes:tcp_merge/1` in the interface: the cut writes the
  header values Erlang chose into each frame of a run as it copies the
  frame, and the merge groups received frames by a fixed rule and
  decodes nothing TCP acts on
  ([design-network-fastpath.md](design-network-fastpath.md)).

Everything else is Erlang. Whether TCP's established path also needs
native code is measured on this stack: a bulk transfer and a
request-response load against line rate at 1 Gb/s (81,274 full-size
frames a second each way, 12.3 us a frame), with the time per frame
broken down by stage: completion, classification, checksum, step,
encoding, posting, the lane crossing and the socket process's hop to the
owner. The measurements on erXos's
kernel decide and those on the Raspberry Pi 4 confirm or reopen the
decision; the same measurements on QEMU on the stopgap are a baseline
that decides nothing, since every interrupt and doorbell there passes the
stopgap's one service thread (plan.md's gates GN-QEMU, GK3 and GN-board).
If the established path misses line rate and the breakdown names a pure
function of the core as the cost, that one function gets a NIF with the
same signature, and the Erlang function stays as its oracle in a
differential test over the same inputs. The process structure does not
change.

The network domain's memory is measured as the storage domain's is (the
system manifest's header): the root's pool pages in use with the domain
up, minus those once it has ended. With the network row on BeamAsm (the development manifest
runs it on the interpreter, which holds less) and the users share's four schedulers and four dirty
CPU schedulers, the domain holds at least 8,463 pages, 33.1 MiB, once DHCP
has leased its address (a lower bound: root's session grows before the
last reading), and 8,603 pages, 33.6 MiB, after root's session has
run `ping -c 3` and echoed 1 MiB over TCP through it (the net_device
suite's network-domain cell on its test manifest: an Apple M3 Max host,
HVF, QEMU 11.1.3, Homebrew clang 23.1.3, one guest CPU, a 768 MiB
machine; the baseline is the pages in use once the domain has ended;
raw logs in erxos-history, `network-domain-footprint-2026-11-11`).

What the domain's lane costs a socket is measured with the net_device
suite's TCP line, through slirp's guest forward to the harness's echo
server, with the stack in the system domain and the lines typed at the
system's Erlang shell (the baseline, commit 1836f6f1e) and with the stack
in the network domain and the lines typed at root's session's, every
socket call crossing the lane (commit c04cfe382); the images differ only
by that move. Over three boots each, a 256 KiB echo took 12 to 16 ms
in-node and 13 to 21 ms across the lane (medians 14 and 18 ms, 17.9 and
13.9 MiB/s each way), and 256 sends of 64 KiB ran at 37.2 to 41.6 MiB/s
in-node and 41.3 to 44.6 MiB/s across the lane (medians 39.6 and 42.8
MiB/s). The sends show no cost of the lane at this rate, which slirp and
the stopgap's device path bound; the echo is too short, timed to the
millisecond, to separate a few milliseconds from noise. These are
stopgap numbers and decide nothing: the stopgap kernel (modified Fiasco),
an Apple M3 Max host at load averages of 7 to 10, HVF, QEMU 11.1.3,
Homebrew clang 23.1.3 with the tree's default flags, BeamAsm, one guest
CPU, a 224 MiB machine (raw logs and the script in erxos-history,
`network-domain-tcp-2026-11-11`).

Costs this design leaves unmeasured are on the performance watch list,
[todo-performance.md](todo-performance.md).

## Verification

Each test below is paired with a seeded failure: a deliberate fault the
test must catch, kept as a fixture, which proves the code under test ran.

### Codecs: fuzz targets

One fuzz target per decoder, in `erx_net`'s `test/*_fuzz.erl`, run by
`make check-fuzz`: Ethernet, ARP, IPv4 with options, IPv6 with extension
headers, ICMP, ICMPv6 with neighbour-discovery options, UDP, TCP with
options, DHCP, epmd's requests, and the socket protocol's requests
through the generated validators. `erx_net_client`'s `test/` holds two
more: the packet-mode framing of `erx_gen_tcp_core` over random streams
cut at random points (`decode_packet` over every mode the options offer),
whose packets must equal those stock's inet driver frames from the same
stream on the host; and `erx_sock_admit` over random terms and over
well-formed pushes and grant answers of every operation with one field
changed, which must accept exactly the messages a reference judge
written from the protocol's types accepts, and
never raise. Each
target checks that the decoder never raises; that encode then decode
returns the record; that it accepts or refuses as a reference judge
does, a short function written from the RFC's validity rules alone; and
that on frames
both accept, its fields agree with those of an independent decoder,
`pkt` (github.com/msantos/pkt, BSD-3-Clause), fetched at a pinned commit
as a test oracle and kept out of the tree. Generators bias lengths to the
edges: empty, one short, exact, one long. A target whose decoder checks
a checksum sets the correct sum on most inputs, so the fields behind it
are reached, and a wrong one on the rest, which the decoder and the
judge must both refuse. The IPv6 and ICMPv6 judges go further: reading
the packet by absolute offsets, where the decoders match binaries, they
state the whole decoded record (extension-header contents, the
fragment, the upper layer's offsets, neighbour-discovery fields and
option values) and, for a refusal FreeBSD answers with a parameter
problem, its code and pointer, which pkt does not decode.

*Seeded failure:* a decoder variant that trusts the IPv4 total length
without checking it against the frame, and one that accepts a TCP data
offset below 5, must each fail its target within the target's budget;
and one that accepts SACK blocks on a SYN, which decodes without
raising, must fail its target's agreement check with the reference
judge, so the judge itself is shown to catch a wrong decoding; so must
an IPv6 decoder that points a routing header's parameter problem at
its segments-left byte, and an ICMPv6 decoder that takes an MTU option
longer than one unit; and an `erx_sock_admit` whose credit check is off
by one, admitting a push one byte past the credit granted, one that
admits a push one byte longer than a piece, and one whose answer check
leaves out the node comparison, admitting an open's socket of another
node.

### Checksums and random values: the interface's gate and the generators

A host test drives the interface process, with the pipe driver's
`process` end and stand-in sockets, through three cases: a segment with a correct checksum
to a connection with room is delivered; the same segment with one bit of
its payload flipped is not delivered, is counted as a bad checksum, and
leaves the connection's credit counter where it was before the frame;
and that corrupted segment sent to a closed port draws no RST, sent to a
listener draws no SYN-ACK and makes no syncache entry, and leaves the
ingress bucket's tokens where they were, as FreeBSD drops it silently.

*Seeded failures:* a `verify/1` that skips the checksum, which must
deliver the corrupted segment and fail the second case; and an interface
that answers a frame naming no socket from its pending value, before
`verify/1` runs, which must send the RST and fail the third.

The random values are checked over the interface core, a datagram
socket's step, a connection's step through an active open and
`erx_dhcp4_core`, each run from a
fixed key over a script of events that draws every kind of value the
module makes:

* the same key gives byte-identical actions on two runs;
* a different key changes the sequence each kind of random field takes
  over the script (identifications, the port search's start, flow
  labels, nonces, delays, the reachable time, the limiter's jitter,
  transaction ids) and nothing else, compared with the random fields
  masked; the keys are fixed, so the test is deterministic;
* the identifications of one socket's successive non-atomic datagrams,
  and the nonces of one address's successive detection probes, are the
  successive draws that key's generator gives, computed by the test with
  `erx_net_rand` alone;
* a spawned owner's generator is `new/1` of the two blocks its spawner's
  generator gave at the split, and the spawner's next draw is the block
  after them, both computed by the test with `erx_net_rand` alone.

*Seeded failures:* an `ip_fillid` that counts instead of drawing, which
the second property must catch, since its values do not change with the
key; a sub-core of the interface that returns the generator it was given
instead of the one it advanced, which the third must catch as a repeated
nonce; and a step that takes a random value from `rand:uniform/1`
instead of its generator, which the first property must catch and the
build check below must refuse; and a `split/1` that gives the child the
parent's key and counter, which the fourth must catch.

### The checksum in the copy: differentials and a lying sum

These test [Checksums in the copy](#checksums-in-the-copy). The
oracle throughout is the plain checksum, `erx_inet_sum` in C and
`erx_bytes:inet_csum/2` in Erlang.

* **The core.** A host test of `erx_inet_copy_sum` covers lengths 0 to
  9,014 and both parities of `offset`, with source and destination at
  every alignment modulo 8. Each copy must leave the destination equal
  to the source, and the returned sum must equal `erx_inet_sum` over the
  destination. The `inet_csum` fuzz target calls it too, under
  AddressSanitizer, over the same random inputs, and checks the same two
  facts. *Seeded failures:* a loop that leaves out a last odd byte and
  one that skips the swap at an odd `offset`, which the test must catch;
  and a loop that reads one word past `length`, which the fuzz target
  must catch.
* **The span.** A property test of `erx_net_sum:span/4` runs over random
  binaries of 0 to 9,000 bytes, with every even `Start` and every
  `Length` that fits, odd lengths included. Each result must equal
  `erx_bytes:inet_csum(0, binary:part(Packet, Start, Length))` as a
  one's-complement value, 0 and 16#ffff counting as equal. *Seeded
  failure:* a `span/4` that leaves the trailer's sum unswapped when the
  trailer starts at an odd offset, which odd-length segments must catch.
* **The decoders, two ways.** Each fuzz target of a decoder above IP
  decodes every input twice: with `none`, and with the true sum of the
  bytes it is given. The two results must be identical, refusals
  included. *Seeded failure:* a TCP decoder that adds the pseudo-header
  twice when given a sum, which refuses every right segment it is given
  a sum for, and the agreement check must catch it.
* **The encoder, two ways.** For random segments, `encode/4` with
  `driver`, finished by an Erlang model of the finisher (the field
  replaced by the complement of `erx_bytes:inet_csum/2` over the range),
  must give the same bytes as `encode/4` with `sender`. A host
  transport's NIF, which runs the core over a frame's pieces as
  `post_frame/5` does, is checked over its fake ring against the
  `sender` bytes. `post_frame/5` itself is checked end to end, below: the hosted
  runtime's one stand-in that carries frames, GENET, finishes no checksums, so
  its transport posts every frame whole with `post/4` and never reaches
  `post_frame/5`. *Seeded failure:* a delayed field
  without the segment's length, which every comparison must catch.
* **The interface's gate, with a lying transport.** This extends the
  gate test of [Checksums and random values](#checksums-and-random-values-the-interfaces-gate-and-the-generators).
  The pipe's `process` end hands up `{sum, S, Frame}`, in four cases:
  1. a correct segment with its true sum is delivered;
  2. the same segment with a wrong sum is not delivered, is counted as
     `bad_sum`, and leaves the connection's credit where it was;
  3. a segment with a payload bit flipped, handed up with the true sum
     of its flipped bytes, is not delivered, because the checksum field
     no longer matches;
  4. that segment handed up without a sum is not delivered either.

  *Seeded failure:* a `verify/1` that ignores a given sum and sums the
  bytes itself, which delivers the segment of the second case. This is
  the test that shows the sum is used. A `verify/1` that skips the
  check fails the third case.
* **End to end.** The network QEMU suite's TCP transfer to the host's
  peer runs through `complete/3` and `post_frame/5`. A wrong sum either way
  stalls it, since the peer's stack drops what our copy finished wrongly
  and ours drops what its copy summed wrongly. The transport's start line
  names `finish copy` or `finish device`. On the FreeBSD test host the netmap run
  through the VALE switch to FreeBSD's jail must end with the jail's
  count of segments discarded for bad checksums
  (`netstat -s -p tcp`) and the stack's `bad_sum` counts both unchanged.
  *Seeded failure:* a `post_frame/5` that stores the sum uncomplemented,
  which must make the transfer fail.

The measurements this change owes are on the
[watch list](todo-performance.md): the stage breakdown of the bulk
transfer, with `tools/erx bench` under HVF, before and after; the FreeBSD
run over tap and netmap, before and after;
and the copy core against a copy followed by a separate sum.

### Classification and framing

The fuzz target of `erx_net_input` generates whole frames, Ethernet and
loopback, IPv4 with options and IPv6 with extension headers and
fragments, carrying TCP, UDP, ICMP and ICMPv6 errors with their quotes,
echo requests, neighbour messages, ARP and other protocols, with lengths
biased to the edges and link destinations of each cast; and a view of
random addresses, groups and DHCP flag, with link-local addresses in two
zones, and a demultiplexing map whose keys are drawn mostly from the
frame's own fields, so that lookups hit. On a DHCP interface it biases
IPv4 frames towards UDP port 68 with malformed options, foreign
destinations and fragments whose payload bytes read as port 68. It runs
`classify/2` on each frame and `verify/1` on what it keeps, and checks
that:

* neither raises, and every verdict and reason is of the closed sets
  [Classifying a frame](#classifying-a-frame) lists;
* the verdict, its destinations and its reason agree with a reference
  judge written from that section's table alone, over `pkt`'s decoding
  of the frame and the same map;
* changing the checksum of the layer above IP, or any byte above IP that
  the table does not name, never changes the verdict of `classify/2`,
  and changes the result of `verify/1` only to a drop for its sum.

*Seeded failures:* a classifier that looks a UDP datagram up by its port
alone, which the judge must catch on a frame to a socket bound to another
address; one that keeps a TCP segment to a broadcast destination for a
listener, which the judge must catch; one that reads a segment's RST
flag to drop it before verification, which the third property must catch
when the flag is flipped; one that builds demultiplexing keys from a
link-local address without its zone, which the judge must catch on a
segment to a socket bound in the other zone; and one that takes port 68
for DHCP only after the IP decision refused the packet as `not_ours`,
re-decoding it, which the first property must catch on a packet with
malformed options to a foreign destination.

`erx_net_frame`'s tests run on fixed configurations:

* `path/3` takes the gateway of a route that has one and the destination
  otherwise, the longest match across two interfaces, the loopback
  interface for an address of the stack in its zone, the zone's
  interface for a zoned destination, and refuses with `enetunreach` and
  `eaddrnotavail` where the section says;
* on an interface with no address and no route, `path/3` with `via`
  gives the DHCP broadcast from `0.0.0.0` to `255.255.255.255`, a router
  solicitation from `::` to `ff02::2` and a duplicate address detection
  solicitation from `::` to the solicited-node group, each with its
  mapped or broadcast link address, while a socket's datagram to
  `255.255.255.255` without a route is `enetunreach`; *seeded failure:*
  a `path/3` that looks a route up for every destination must fail the
  first three;
* a multicast destination's path has hop limit 1, an IPv6 path the IPv6
  link MTU below the interface's MTU, and an IPv4 address with no
  matching prefix takes the interface's first address in the order
  added; *seeded failure:* a path that takes the interface's hop limit
  for a multicast must fail;
* a socket's broadcast, and an IPv6 multicast to all-nodes with the loop
  option on, framed and handed back as `loop`, are owned by a local
  socket bound to the port; with the loop option off nothing is handed
  back; and an ICMPv6 address-unreachable error the interface sends to
  its own link-local address, through the loopback interface, is owned
  by the socket its quote names; *seeded failures:* a sender that loops
  nothing must fail the first, and a loopback that drops the zone must
  fail the last;
* every frame `tcp/3` and `address/3` make decodes, through the codecs
  with their checksums checked, back to the segment's header and payload
  with its ECN field and don't-fragment, an identification of zero under
  don't-fragment and the generator's next draw otherwise, and the
  payload binaries it was given; broadcast and multicast destinations
  carry their link addresses; no row gives `resolve` with packets that
  decode the same;
* a connection's segments framed by `erx_net_frame` and classified by
  the peer's `classify/2`, with a view holding the reversed key, come out
  owned by the peer with the same `segment()`;
* an IPv4 connection whose context MTU drops from 1,500 to 1,280 bytes
  in mid-transfer sends its next full segment sized to 1,280 bytes less
  its headers and options, with `t_maxseg` lowered, and `tcp/3` never
  returns `emsgsize`; *seeded failure:* an output that sizes by
  `t_maxseg` alone must make `tcp/3` return `emsgsize`.

*Seeded failures:* a path that addresses the destination although the
route has a gateway; an encoder that writes the ECN field into the
DSCP bits; and a multicast mapping that keeps 24 low bits instead of 23;
each must fail its case.

With the processes, host tests check the published state:

* two transmitters that see one stale row give the interface one hint,
  and another after the row is published again; a transmitter whose row
  was deleted before its increment sends no hint and leaves no row;
  *seeded failures:* a loop that hints without the count must send two,
  and one that increments with `update_counter/4` and a default must
  leave a row;
* an interface killed after publishing neighbour, address and route rows
  leaves none of them once `erx_net_tables` has its monitor message, and
  the generation has moved; a restarted interface that publishes before
  that message keeps its own rows through the deletion, and a path built
  for it finds none of the old incarnation's rows even before the
  deletion; *seeded failures:* a deletion keyed by interface name must
  lose the new incarnation's rows, and a `snapshot/3` without the pid
  check must show the old incarnation's address;
* a router advertisement that only extends an address's lifetimes
  changes no row and leaves the generation as it was, and the preferred
  deadline passing sets `deprecated` and moves it; *seeded failure:*
  rows that carry their deadlines must move the generation on the
  refresh;
* the segments a connection reinjects after the one that ended it reach
  a listener of the same port, and without one draw a RST within the
  limit, and one whose frame was link broadcast draws none; *seeded
  failure:* a reinjected segment looked up by its full key must reach
  the ended connection's dead pid and be lost.

### Reassembly and buffers: properties against a byte map

`erx_ip4_reass`, `erx_ip6_reass`, `erx_tcp_reass` and the receive buffer
are checked against a model that records every byte position as a map:
over random sequences of overlapping, duplicate and out-of-range pieces,
the delivered bytes equal the model's, RFC 5722's discard happens exactly
when the model sees an overlap, and the held bytes never exceed the caps.

*Seeded failure:* a reassembly that accepts overlapping IPv6 fragments;
the property must find the overlap.

### The TCP core: exhaustive exploration

`erx_tcp_explore` drives a connection with small buffers and windows,
and a model of its peer, over an abstract alphabet: segments with every
combination of SYN, ACK, FIN and RST and with or without data, at each
sequence position class (below the window, at `rcv_nxt`, inside, at the
right edge, beyond) and each acknowledgement class (below
`snd_una - max_sndwnd`, old, at `snd_una`, in flight, at `snd_max`,
beyond), plus user requests (send, recv, close, shutdown, abort) and
expirations. It explores breadth-first, applying every event of the
alphabet in every state it reaches, and merges states that agree on an
abstraction of the control block (the TCP state, the FIN state, which
send and receive variables are equal, which deadlines are set, the
recovery state) and on how the peer model stands against the connection
(its window's right edge against `snd_una + snd_wnd`, `snd_max` and its
furthest acknowledgement, its
SND.WL1/WL2 and furthest acknowledgement against the connection's, and
the urgent bytes still ahead of delivery), so a state the model judges
more strictly is explored on its own, until no new abstract state
appears, or to depth 8. The
whole exploration runs again with the initial sequence numbers just
below 2^32, so every position class is also crossed at the wire
boundary. On every transition it checks:

* `snd_una =< snd_nxt =< snd_max`, and `rcv_nxt` never decreases;
* no byte is delivered twice or out of order, and none beyond what the
  peer sent;
* no segment is sent beyond the peer's window, except a window probe of
  one byte. The window is the peer model's newest, kept by the SND.WL1/WL2
  rule as FreeBSD's step 6 applies it to the segments that pass the
  sequence and acknowledgement checks as the model judges them, counted
  from the furthest acknowledgement taken: FreeBSD takes the window of
  an acknowledgement below `snd_una` as counting from `snd_una`
  (`tcp_input.c`'s step 6), where RFC 9293 ignores it. The one window
  the connection may leave untaken is that of a segment FreeBSD could
  count as a duplicate acknowledgement, which the loss module may end
  before step 6: the acknowledgement at `snd_una` with the retransmit
  timer set, not a first FIN, and without SACK no data and the window
  unchanged, with SACK a block `tcp_sack_doack` takes (`tcp_input.c`
  2568-2606);
* a RST resets only at exactly `last_ack_sent`; challenge ACKs never
  exceed their limit;
* an old acknowledgement never changes the send window (SND.WL1/WL2);
* every state change is one RFC 9293's state diagram allows;
* where header prediction accepts the segment, the general stages give
  the same state and actions;
* an urgent byte of a segment taken at `rcv_nxt` with nothing held for
  reassembly, before the peer's FIN, is kept out of the stream, since
  this step delivers it if anything does (`tcp_pulloutofband`);
* the step never raises.

The base alphabet leaves out dimensions the core also decides on, each of
which would multiply its size. Each runs as an exploration of its own,
the base alphabet plus that one dimension's variants of its segments
(none of a RST, which is judged before anything a dimension varies),
with the abstraction widened by the state the dimension reads, to a
depth bound of its own (5 to 8 events), since each level costs two to
three times the one before:

* **timestamps:** a segment without the option, and with a value older
  than, equal to and newer than `ts_recent`, on connections that
  negotiated timestamps and that did not, so the `timestamps` stage and
  PAWS are reached in every state; the clock never reaches
  `TCP_PAWS_IDLE`, so `ts_recent` is never invalidated by age;
* **ECN:** ECE and CWR on segments and the CE mark in the IP header, on
  connections with ECN negotiated and without;
* **urgent data:** URG with the pointer inside the segment, beyond it and
  beyond the window; no pointer reaches past `SB_MAX`, so the rule that
  drops such an URG is not explored;
* **SACK:** duplicate acknowledgements carrying no block, a block inside
  the flight, a block beyond `snd_max` and a block below `snd_una`
  (D-SACK);
* **the peer's window:** zero, below one MSS and full, so persist,
  window probes and silly-window avoidance are reached, and a SYN with
  window scaling or with FreeBSD's least MSS (`tcp_minmss`, 216 bytes).
  That MSS is larger than the base's buffers, so this dimension's
  connection has a send buffer of two such segments and more, and one
  output pass sends more than one segment (`sendalot`); an
  acknowledgement carrying MSS and window scale, options only a SYN may
  carry; and `sndbuf` raised and lowered by a quarter and by half the
  buffer, with the user's `send` played by a stand-in socket process
  that spends all the send credit it holds whenever bytes wait, so the
  grant rule meets persist and its probes;
* **ICMP reports:** fragmentation-needed or packet-too-big, and
  unreachable, each quoting `snd_una` (in flight when anything is) and,
  never in flight, the number below it, `snd_max`, and the number 2^31
  past `snd_una`, which a comparison of wire numbers rather than lifted
  ones would place on either side, in every state.

Their added properties: a segment PAWS drops changes none of the
connection's sequence state, its window or `ts_recent`; a report quoting a sequence number outside
`snd_una` to `snd_max` changes nothing; a window probe is sent only while
the peer's window is zero; no state leaves the send buffer room while no
credit is outstanding, bytes wait in the stand-in and the peer has
acknowledged every byte sent or offers a zero window, the window probe's
state included; the send buffer's bytes plus the credit outstanding
never pass its size; no segment carries more data than the MSS;
CWR is sent only after the window was reduced, on ECE received or after
a segment was sent again on a timeout or three duplicates
(`cc_cong_signal` owes CWR for `CC_ECN`, `CC_RTO` and `CC_NDUPACK`
alike); and the step's results in the presence of an unnegotiated option,
or of MSS and window scale on a segment without SYN, equal its results
without it.

*Seeded failures:* the window update without the WL1/WL2 rule; a window
update that never shrinks the window; a window shrink ignored on a pure
acknowledgement at `snd_una`; a duplicate acknowledgement counted
whatever window it offers; an urgent byte delivered in band; RST
accepted anywhere in the window; RST judged against `rcv_nxt` with an
acknowledgement delayed; `rcv_nxt` advanced without lifting; an ICMP
report acted on without its sequence check, or checked against `snd_max`
alone; header prediction that skips the timestamp precondition (PAWS);
PAWS that never drops an older segment; challenge ACKs counted past
their limit; a grant rule whose second clause asks only that every byte
sent be acknowledged, which a full buffer behind a zero window, a probe
out and `sndbuf` raised by a quarter must leave with room ungranted.
Each must be caught with a named property and the shortest trace.

### The syncache: properties at its boundaries

`erx_tcp_syncache` is pure, so its decisions are checked with virtual
time against properties written from FreeBSD's rules:

* a cookie made under the current secret validates now and after one
  rotation, and not after two (15 to 30 s);
* the fields recovered from a valid cookie (the MSS and window-scale
  indexes, rounded down as `tcp_sc_msstab` and `tcp_sc_wstab` round, and
  SACK permitted) equal those of the SYN that made it;
* a cookie with any bit of its MAC changed, or for another four-tuple,
  does not validate;
* an ACK matching no entry is checked as a cookie exactly when the table
  is paused or overflowed in the last 15 s, and at 15 s exactly as
  FreeBSD's comparison decides;
* the table never exceeds its bound, and a SYN that finds it full gets a
  cookie and no entry, drops every entry and pauses the table;
* a pause ends when the uptime reaches its end, makes no entry until
  then, and lasts 15 s, doubled for each pause that starts within the
  last one's length after it ended, to at most 960 s.

*Seeded failures:* a rotation that drops the previous secret at once,
which the first property's one-rotation case must catch; an overflow
window measured with `=<` where FreeBSD uses `<`; a pause held through
the second it ends.

### The send log, loss and congestion: properties and a FreeBSD oracle

The RFC 6675 scoreboard computed from the send log is checked against
RFC 6675's definitions written directly over a byte map. CUBIC's
arithmetic is checked differentially against FreeBSD's own: the inline
functions of `cc_cubic.h` at the pinned commit, compiled on the host as a
test harness from the fetched source, over random inputs.
`erx_tcp_rtt` is checked against RFC 6298's formulas.

*Seeded failure:* CUBIC's `K` computed with a rounding direction
reversed; the differential test must report the first diverging input.

### Packet scripts against FreeBSD

FreeBSD's TCP test suite (github.com/freebsd-net/tcp-testsuite,
BSD-3-Clause, fetched at a pinned commit) is a set of packetdrill
scripts covering every segment type in every TCP state, overlapping
received data, the socket API and ICMP, in IPv4 and IPv6 variants. Two
runners execute it:

* **On FreeBSD.** The FreeBSD x86-64 test host, running FreeBSD
  16.0-CURRENT, runs the scripts with nplab's packetdrill, the version
  the suite names. packetdrill is GPL-2.0, so it is built and run only on
  that host as a test tool, never linked to or shipped with anything of
  erXos's. Each run writes one verdict record per script: the suite's
  commit, the script, its verdict, the kernel's identity as
  `freebsd-version -k` and `uname -v` print it, and packetdrill's
  version. The records are raw run data and live in the separate history
  repository, never in this one.
* **On erXos.** `erx_net_script`, erXos's own runner in Erlang, reads
  the scripts' language, with no code of packetdrill's, and drives the
  stack under the virtual clock ([The clock](#the-clock)) in two ways:
  against the pure core, and against the whole stack on a development
  host through the pipe driver's `process` end, so the effect layer runs
  too. A script's socket calls become socket requests; its packets are
  injected at the pipe; its expected packets are matched against what
  the pipe is given. The whole-stack runs are made twice, the second
  through the `process` end's offload mode, which cuts runs and batches
  bursts through the C of the cut and the merge
  ([design-network-fastpath.md](design-network-fastpath.md#tests)).

The oracle is a moving -CURRENT, so a comparison names the kernel it
compares with: every script's verdict on erXos must equal its verdict in
the newest record, whose kernel identity the comparison's own record
repeats. A difference is a bug, a documented departure with a test, a
recorded FreeBSD bug, or a change FreeBSD made after the pin
(`975e3605ebb1`), recorded with the FreeBSD commit that made it. A
difference that a change between `release/15.1.0-p6` and the pin
explains is a bug of the port when the change is one the wire can see,
since those are ported ([Provenance and notices](#provenance-and-notices)). A script whose verdict differs between two records of
FreeBSD is a change of the last kind until shown otherwise, and is
triaged against the pinned source before any erXos verdict is judged
against the newer record. erXos's own scripts, run by both runners in the
same way,
add the decisions this document names that the suite does not cover: a
RST at `rcv_nxt` while an acknowledgement is delayed, which FreeBSD
answers with a challenge ACK because it judges against `last_ack_sent`;
a segment without a timestamp on a connection that negotiated them, and
one with a timestamp on a connection that did not; an acknowledgement of
exactly `iss` on either side of the old-acknowledgement bound; FIN-WAIT-2
ending at its idle limit; and segments at the 2^31 sequence distance,
which pin the departure that lifting makes.

*Seeded failures:* the RFC 5961 RST check removed must fail the suite's
RST scripts on erXos; a script edited to expect a wrong window must fail
on both runners, which shows the runner compares fields rather than
passing everything; and an interface loop that arms its timer a second
after the core's deadline must fail the suite's retransmission scripts
through the pipe, though not against the pure core, which shows the
effect layer's timing is what those runs check.

### The stack on a development host

The host runs of [Running on a development host](#running-on-a-development-host)
take three peers:

* **QEMU's user networking on macOS.** The stack takes a DHCP lease from
  slirp through the `-machine none` hub, resolves slirp's gateway by ARP,
  and runs UDP echo and a TCP transfer to a service on the host through
  slirp. *Seeded failure:* an ARP reply with its sender and target
  swapped must leave slirp unable to reach the stack, so the transfer
  times out, which shows slirp spoke to the stack's own ARP.
* **FreeBSD's jails on the test host.** The host's tap devices `/dev/tap0` to
  `tap7` join a bridge with the vnet jails `erxpeer0` to `erxpeer3`
  (10.77.0.10 to 10.77.0.13/24), whose stack is the oracle's own kernel;
  the stack runs on the host's own OTP over a tap device through the tap
  transport ([The tap transport](#the-tap-transport)). Bulk transfers, many short connections
  and request-response loads run between the stack and a jail through
  `erx_net_relay`, and the same loads between two jails, each joined to
  the relay through a tap device of its own, under the same
  schedule, are FreeBSD's baseline. The tests
  check completion, delivered bytes, and that retransmissions and
  throughput stay within stated bounds of the baseline's. Each run's
  record names the kernel as the packet scripts' records do.
  *Seeded failure:* SACK disabled on erXos must push its retransmissions
  past the bound under a loss schedule where FreeBSD recovers with SACK.
  `tools/erx bench net-freebsd` reaches the host by the ssh name that
  `--host` or `ERX_NET_BENCH_HOST` gives.
* **erXos itself.** Two stacks in one node, each through its pipe's
  `process` end to one `erx_net_relay`, under the virtual clock, run bulk
  transfers and many short connections under seeded schedules, each pair
  in a node of its own with one scheduler ([The clock](#the-clock)) and
  as many pairs at once as the host has cores; long waits (2MSL, keepalive,
  FIN-WAIT-2's idle limit) take no time. *Seeded failure:* a receive
  path that drops out-of-order segments instead of queueing them must
  exceed the retransmission bound under a reordering schedule.

**The impairment.** `erx_net_relay` forwards frames between two ends,
each a pipe-shaped `process` or `udp` end or a tap device through
`erx_tap_nif`, and runs each direction
through `erx_net_impair`, a pure state machine keyed by a seed:

```erlang
-type config() :: #{seed := <<_:128>>,
                    loss := 0..1000, duplicate := 0..1000,   % per mille
                    reorder := 0..1000, delay := {Min :: non_neg_integer(), Max :: non_neg_integer()}}.
new(config()) -> impair().
frame(Frame, Now :: integer(), impair()) -> {[{At :: integer(), Frame}], impair()}.
```

`frame/3` decides each frame's fate in order from an `erx_net_rand`
generator keyed by the seed, one split per direction: none (lost), one
copy or two (duplicated), each released at its own time; a reordered
frame is held an extra delay, so that the frames after it overtake it. The relay releases frames
through `erx_net_clock`, so under the virtual clock a schedule is
reproduced exactly, and against real peers the decision for the n-th
frame of a direction is still a function of the seed. A `udp` end is
pinned to its peer and drops strangers, as the pipe's does, so nothing
else on the network can put frames into a run. The same relay sits
between a QEMU guest's `dgram` backend and its peer in the runs of
[Traffic against FreeBSD and Linux](#traffic-against-freebsd-and-linux).
*Seeded failure:* a schedule that ignores the seed, and so gives two
seeds the same decisions, must fail the property that two seeds give
different schedules over a thousand frames; a schedule that shares one
generator between directions must fail the property that one direction's
decisions do not change with the other's traffic.

**The driver and the clock.** A host test drives the pipe driver with a
stand-in interface: a batch refused by a full receive credit is dropped
whole and counted, and leaves the credit where it was; a link that goes
down and up again while the receive credit is full is not told at all,
and one that goes down and stays down, with no frame after it, is told
once when room returns; a transmit backlog never holds more frames than
the transmit credit's limit; 10,000 datagrams from a stranger to a
`udp` end never put more than 65 messages in the driver's queue; and a
`process` end's frame that is not a binary is counted as `malformed`
with no raise in the interface. A `process` end's far end that ends,
or an exit signal from a process linked to the driver, ends the driver
no sooner than a second after its start; the stack started over a
`process` end named by a registered name answers ARP, its far end is
killed, and the link restarts and answers ARP through a new driver to a
new far end under the name; and a name with nothing registered restarts
the link two to four times in 2.5 seconds with the stack's supervisors
unchanged, as does a transport that crashes at once at every start.
*Seeded failures:* a driver that takes a
frame's unit when its message arrives instead of when the frame leaves
must let the backlog exceed the limit; one that queues every link change
must fill the credit under a flapping far end; one that retries a link
notice only at later messages must never tell the silent link; a socket
opened `{active, true}` must exceed the queue bound; a `process`
end without its type check must show the interface's raise; a pipe that
reports the link `down` on its far end's end, the driver staying alive,
must never answer the new far end; a driver that ends at once, or an
interfaces supervisor at OTP's default intensity, must let the far end
that is never there end the supervisors; and a link start that fails
when its driver crashes under it must fail the stack's start. A
virtual-clock test checks that every process's hint arrives at or after
its deadline, that the clock holds one deadline per caller after a
million arms, and that two runs of one script and seed give
byte-identical frames; *seeded failures:* a socket that arms an
`erlang:start_timer/3` of its own must fail the build check below, and
its script, whose retransmission then comes on the wall clock rather
than at its virtual time; an interface that draws its key from
`erx_bytes:entropy/1` directly must fail the build check and the
byte-identical run.

**The tap transport.** On the FreeBSD test host, frames of 60, 1,514
and 9,014 bytes cross the transport both ways unchanged, a run is cut
into the frames `erx_net_frame:cut/1` gives, and a tap destroyed under
it ends the medium and the driver. *Seeded failure:* a `send/2` that
answers a run as taken whole when the device would block before its last
frame must fail the run's frame count.

### Traffic against FreeBSD and Linux

Bulk transfers, many short connections and request-response loads run
between an erXos guest on QEMU and a jail of the FreeBSD test host, and
between erXos and the Linux oracle guest, through `erx_net_relay` with a
seeded schedule. For a jail, the relay runs on the test host, its `udp`
end pinned to the guest's `dgram` backend across the network and its
other end on a tap device of the jails' bridge, through `erx_tap_nif`. The tests check
completion, delivered bytes, and that retransmission counts and
throughput stay within stated bounds of FreeBSD's own against the same
schedule, as the host runs above do.

*Seeded failure:* the host runs' seed, SACK disabled on erXos, run on
the guest.

### The socket process: exploration and two domains

**The core, explored.** `erx_gen_tcp_core` is a protocol state machine
between three parties, the owner, the socket process and the socket, so
it is explored exhaustively, as the TCP core is. The socket is modelled
as the bytes its peer has sent and the receive credit it holds, pushing
whenever it has both, at most a piece at a time, and as a send buffer
with a high watermark of 3 bytes, which sends while the peer's window
is open, which the peer acknowledges a byte at a time, and which grants
send credit by the grant rule of **Send credit**, both clauses. The lane
from the socket process to the socket is a queue with a busy limit of
2 bytes, counting a piece as its bytes and any other message as one:
the outlet refuses while the queue is at the limit or past it, and the
model then owes the socket process one notification, which it delivers
once the queue is below the limit; the socket takes one message at a
time. The shell's rule, that a refused `next_out` leaves the core as it
was and that nothing more is offered until the notification, is part of
the model. The alphabet: the socket taking the next message from its
lane, the socket granting its whole high watermark again without
taking anything, as a hostile network domain may, a notification no
refusal asked for, the peer sending one to three bytes, the peer
acknowledging a byte, the peer closing and opening its window, `eof`,
`{error, econnreset}`, the socket's exit, `setopts` of each active mode
with `N` of -1, 1 and 2, and of `show_econnreset` and
`send_timeout_close`, `recv` of 0 and of 1 to 5 bytes, `send` of one to
three bytes from each of two callers, the deadline of each waiting send
passing, `shutdown` of the write side, `close`, a `getstat` from each of
two more callers, so that a call must wait for a place, the two calls
of `controlling_process`, the owner's exit, and replies in and out of
order; and, from the start in `opening`, the hand-over, and a push, a
grant of send credit and a link exit sent by the network domain before
the socket process's first message, as a hostile network domain may;
to depth 10, with a `buffer` of 4, a piece of 2 bytes and 2
places for calls in flight. In every reachable state:

* before the hand-over the socket process holds nothing the network
  domain sent, and anything the network domain sent before the socket
  process's first message has ended the opening; a socket that follows
  the protocol sends nothing before that message, so in a run in which
  the socket follows it, only the socket's own end (its exit, for a
  reset that arrives before the hand-over) ends an opening;
* during a transfer the socket process holds no more than the target,
  whatever the socket pushes;

* the bytes the owners received, in `{tcp, S, Data}` and in recv
  replies, taken in order, are a prefix of the bytes the peer sent, and
  each byte presented reaches one owner once;
* the bytes the socket received from sends are the sends one after
  another, in the order they were called, each whole or, for a send
  answered `{error, {timeout, Rest}}`, short by exactly `Rest`, so no two
  interleave, none is lost to a refusal, and no byte a caller was given
  back reaches the peer;
* no push and no piece sent carries more than a piece, and at most 2
  calls are in flight;
* the bytes sent never exceed the send credit granted, and the send
  buffer's size is never less than its bytes plus the credit
  outstanding;
* no send waits for credit while the buffer has room, no credit is
  outstanding, the peer has acknowledged every byte sent or offers a
  zero window, and no grant is in flight;
* a `send` is answered `ok` only once its last byte is queued, and no
  byte is sent after `shutdown` of the write side or `close`;
* when the socket ends, the first send waiting, or, if none waited, the
  first send after the end while the owner has not been shown it, is
  answered `econnreset` exactly when the end is a reset and
  `show_econnreset` is on, and `closed` for a reset without it; every
  other send is answered `closed`;
* nothing is presented after the reply to a `setopts` of
  `{active, false}` until the next active `setopts`, and nothing while a
  transfer is under way;
* the active count is stock's: `{active, N}` on a count `M` makes it
  `M + N`, and `{tcp_passive, S}` is sent exactly when the count reaches
  zero or less;
* the end is presented once, after every byte held;
* the bytes held plus the credit outstanding never exceed the target;
* no recv waits while the socket holds bytes it may not push, no grant
  is in flight and the lane is not refused;
* every call is answered once, `close/1` without waiting for the lane;
* the lane holds no more than the busy limit and one message past it,
  whatever the socket grants;
* the socket process is never refused with no notification owed, so
  nothing waits in it for a lane that has room.

A run in which the socket grants without taking keeps no send buffer of
its own, so only the lane's bound, the order of sends and the answers
to calls are checked in it.

`erx_gen_udp_core` is explored the same way, with datagrams of one to
three bytes, a largest datagram of 3 and a floor of 6 for the target; in
every reachable state, besides the properties above that apply to it, no
datagram waits in the socket while the socket process holds nothing.

*Seeded failures:* a core that presents a push during a transfer instead
of holding it must break the order property with two owners; a shell
that postpones every push during a transfer, as stock's `gen_tcp_socket`
does, must break the transfer's bound when the socket grants without
taking; a shell that postpones a push in `opening` must break the
property that it holds nothing before the hand-over; a socket that
grants its first send credit when it links, before the first receive
credit, must end an opening in a run where the socket follows every
other rule; one that
grants credit again when a push arrives, not when it is presented, must
break the bound in passive mode; one that grants only at half the
target, never for a waiting recv, must leave a `recv` of 4, after one
byte presented, waiting with the bytes in the socket; one that sends
`tcp_passive` before the last delivery of its count must break the
passive property; one that sends the second caller's first piece before
the first send's last byte must break the order of sends; one that cuts
its pieces at the piece but not at its credit must break the send
credit bound; one that answers a send when its first piece goes must
break the answer property with a send of 3 bytes and a credit of 2; one
that leaves waiting sends in place at `shutdown` must send a byte after
it; one that drops a timed-out send's rest instead of returning it, and
one that still sends it after the answer, must each break the property
of whole sends; one that answers a send waiting at a reset `closed`
whatever `show_econnreset` says must break the reset property, and one
that gives every waiting send the end's reason must answer the second
caller's waiting send `econnreset`; a socket model whose grant rule
lacks its second clause must leave a send of one byte waiting after the
peer acknowledges a byte of a full buffer and closes its window; one
that drops a call past its places instead of holding it must leave a
call unanswered; one that sets the active count to `N` instead of
adding it must break the count property; a shell that keeps the core's
next state when the outlet refuses must lose the refused piece from the
stream, which shows that committing only on `ok` is what keeps it; a
core that counts refused receive credit as outstanding must leave a
`recv` of 4 waiting with the bytes in the socket after the lane drains;
one that ignores a refusal and offers its next message at once must
break the lane's bound when the socket grants without taking, which
shows the refusal is what bounds the lane; a lane model that owes no
notification after a refusal must leave a send waiting with the lane
empty; and a datagram core whose floor is the largest datagram, not
twice it, must leave a datagram of 3 waiting in the socket while the
socket process holds nothing.

**The connection's side of send credit.** A host test drives a
connection from a test process standing in for its socket process,
against a peer that acknowledges on a seeded schedule and sometimes
stops: across every step the send buffer's bytes plus the send credit
outstanding stay within its size and the grant's reservation equals the
size, autosizing included; a fresh connection pushes nothing before its first receive credit, and its first push then grants the
whole high watermark; a stand-in that fills its credit and waits
receives the next grant once the peer has acknowledged half the buffer;
with a 64 KiB buffer full, a peer that acknowledges 16 KiB and closes
its window must bring a grant of 16 KiB at that step; with a 64 KiB
buffer full behind a zero window, a window probe answered with the same
acknowledgement and `sndbuf` then raised to 80 KiB must bring a grant of
16 KiB at that step; a stand-in that takes 64 KiB of credit and then
sets `sndbuf` to 4 KiB must spend all of it without an abort, the
reservation staying at 64 KiB until the peer has acknowledged 60 KiB
and falling to 4 KiB as the rest goes; a request-reply run of 1 KiB
requests on a 64 KiB buffer must cost one credit message per 32 KiB of
requests; bytes past the credit, and bytes after `shutdown` of the
write side, each end the connection with a RST and
`{error, econnaborted}`, counted; a stand-in that exits ends the
connection through their link as `close/1` does, with a FIN after the
bytes it sent; and bytes sent to a connection that a RST has just ended
are dropped without a crash. The grant rule, a pure function, is also
checked over every high watermark, buffer, credit, acknowledgement and
window state up to 8 bytes: it never grants past the high watermark,
grants under its first clause only at half the watermark or more, and
leaves no state with room, no credit outstanding and every byte
acknowledged or a zero window without a grant. *Seeded failures:* a
connection that grants when a segment is sent rather than when it is
acknowledged must break the size bound; one that grants only at half
the buffer, never at its start, must leave the first send waiting; one
without the second clause must leave the stand-in without credit behind
the closed window; one whose second clause asks only that every byte be
acknowledged must leave the stand-in without the 16 KiB behind the
probe; one whose second clause ignores the credit outstanding must cost
a credit message per request-reply exchange; one that lowers its
reservation to the new `sndbuf` at once must let the grant's total fall
below the bytes the connection holds; and one that takes bytes past its
credit into the buffer must let the stand-in grow the buffer past its
size.

**What the bench must show.** The network bench
(`bench/erx_net_bench.erl`) runs the package against master: rr-64 at
`+S 1:1` and with default flags, and bulk send and receive of 512 MiB,
in interleaved rounds, on the FreeBSD x86-64 test host. It must show
the send's reply and the socket process's schedule gone from rr-64's
trace, one message a transaction fewer than master's, CPU per
transaction lower than master's beyond the rounds' spread, and bulk
within noise. A throwaway change of the socket process that answers a
fitting `send` at once and of the connection that answers no `send`,
granting by the first clause alone, meets this bar, and its record is
cited in [todo-performance.md](todo-performance.md); the package must
reproduce its figures within the rounds' spread. There every socket is
in one domain, so the outlet sends plainly and refuses nothing. On QEMU
under HVF with the owner in a test domain, rr-64 and a 64 MiB bulk send
are recorded against master, with the lane crossings per transaction,
two, counted from the connection's and the socket process's counters,
and the outlet's refusals and notifications counted from the socket
process's: with a network domain that keeps up, the 64 MiB send must
show refusals only while the queue is past the busy limit, each
followed by one notification, and the bytes it copied for its tail at
most the busy limit and two pieces. The same QEMU runs, with the bell
of [design-runtime.md](design-runtime.md#connections-in-erts) standing
in for the notification, are recorded first, so the edit's gain over the
bell is a measured number.

**Two domains on QEMU.** An owner in a test domain, beside the network
domain, runs stock code unchanged: `receive {tcp, S, Data}` loops in
`{active, true}`, `once` and `N`; `controlling_process` between two of its
processes with data in flight, checked byte for byte; an owner that
exits, whose peer must see a FIN; a socket process killed, whose peer
must see the connection close; a connection killed in the network
domain, whose owner must receive `{tcp_error, S, econnaborted}` and
`{tcp_closed, S}`; and a passive socket whose owner never reads, whose
connection's window must close while its socket process holds no more
than its `buffer`. With the test domain's `max_frame` at 128 KiB, a
`gen_tcp:send` of 1 MiB and one of 100 MiB, and a `recv(S, 8 MiB)` on a
connection whose receive buffer is 4 MiB, must each complete, checked
byte for byte; 100 processes that each send 64 KiB on one socket at
once must all be answered, each send's bytes contiguous at the peer;
100 acceptors on one listener must each receive a connection; and an
`accept` with a timeout of one second, called behind 64 others that
wait, must time out one second after one of them is answered, the
documented difference of [Requests in flight](#requests-in-flight). A
second test domain, holding `net` with its `max_frame` at 64 KiB, must
have its `gen_tcp:connect`, `gen_udp:open` and `inet:getifaddrs/0` each
answer `{error, enobufs}` at once, the grant's counts must show no
request from that domain, and the domain's log must hold one line per
operation naming the limit and the floor; the same holds for a domain
whose `max_message_heap` is 1 KiB, the case of a correct push of 64
small binaries that its funnel would drop, and for a domain whose
`max_frame` is 1 byte, the least domain admission allows
(`liberx/system/dom_core.c`), whose refusal therefore never crosses a
lane. Seeded failure: `erx_inet` without the comparison, under which
the 1-byte domain's `inet:getifaddrs/0` sends its request, the
answer is dropped by its own funnel and the call misses the test's
deadline. With its
`max_frame` at the generated floor, a grant serving 64 interfaces of 64
IPv6 addresses each must answer its `inet:getifaddrs/0` whole. A third
domain, handed the socket term and the connection's pid, sends the
socket process crafted `{erx_net, Conn, {data, Pieces}}` messages, none
of whose bytes may reach the owner; and a process of the owner's domain
other than the socket process sends the connection a well-formed request
and a `{send, Piece}`, which must have no effect, no byte of the piece
reaching the peer. A `gen_tcp:send` of 100 MiB to a peer that stops
reading for ten seconds and then reads must complete byte for byte,
with the connection's send buffer never past its high watermark. A
`send` in `{packet, 4}` with a `send_timeout` of one second to a peer
that does not read must answer `{error, {timeout, Rest}}`; the owner
then sends `Rest` in `raw` mode, restores `{packet, 4}` and sends one
more packet, and once the peer reads it must receive both packets
whole, as OTP's `otp_7816` case does. The same send under
`send_timeout_close` must answer `{error, timeout}`, and the peer must
see the connection close after the bytes that went. With
`show_econnreset`, a send that waits on a full buffer when the peer
resets must answer `{error, econnreset}`, and without it
`{error, closed}`; with two writers waiting on a full buffer under
`show_econnreset`, the first must answer `{error, econnreset}` and the
second `{error, closed}`, as stock's socket backend answers them. A test
grant that lies answers an open with a pid of the third domain and
`interfaces` with an interface name that holds an escape byte; each call
must answer `{error, badarg}`.

*Seeded failures:* an `erx_sock_admit` that takes `{erx_origin, _, Inner}`
without comparing the origin must let the third domain's bytes reach the
owner, which shows the comparison is what stops them; a connection that
skips its check of `ReplyTo` must act on the direct request and put the
other process's piece into the stream; a socket
process that passes a push on without taking its envelope off must leave
the stock `receive` loops waiting, which shows the deliveries pass
through the socket process; a socket process that sends a send whole,
and a connection that pushes all its credit in one message, must
respectively fail the 1 MiB send's check at the peer, its bytes lost
with the dropped frame, and leave the 8 MiB recv unanswered past the
test's deadline, which shows the pieces are what keeps frames within
`max_frame`; an `erx_inet` without its floor check must let the second
test domain's connect succeed and its first `recv` of a full piece wait past
the test's deadline, the hang the check exists to turn into an error,
and one that checks only `max_frame` must let the domain with a 1 KiB
`max_message_heap` open a socket whose first push of 64 small binaries
its funnel drops, its `recv` waiting past the test's deadline; a
generator whose `max_frame` floor ignores the grant's replies must let
the second domain's `inet:getifaddrs/0` with 64 interfaces wait past the
test's deadline; a socket process that still sends a timed-out send's
`Rest` must leave the peer a second packet whose header is the first
packet's bytes; and an answer check that leaves out the node comparison
must let the lying grant's open answer `{ok, S}`.

**A network domain that stops draining.** A fourth test domain stands
in for the network domain: its grant opens a connection whose socket
grants 2 MiB of send credit and is then suspended by a process of its
own domain, which runs with a small `-erx queue_quota`, so the funnel
pauses the lane from the owner's domain at the first frame past the
quota and the lane fills, as a hostile network domain could make it.
In the owner's domain a `send` of 4 MiB with a `send_timeout` of one
second must answer `{error, {timeout, Rest}}` within two seconds; a
`recv` with a timeout of one second must answer `{error, timeout}`
within two; `gen_tcp:close/1` must return at once; and once the owner
exits, the socket process must be gone within a second. On a second
connection, suspended the same way after its first grant of 2 MiB, the
suspending process sends the socket process one more grant of 2 MiB
under the socket's pid, as a network domain that grants without
reading would, and pushes 4 MiB of data that the owner, in
`{active, true}`, consumes: a `send` of 16 MiB with a `send_timeout` of
one second must answer `{error, {timeout, Rest}}`, and the owner
domain's queue for the network domain, read from its runtime's
counters, must stay within the busy limit and a frame per sending
process, whatever was granted and pushed; the receive credit the socket
process could not send must reach the socket as one grant once the
suspending process lets the lane drain. A third connection carries a
`send` of 100 MiB from a binary that is the only reference to its data,
with a `send_timeout` of one second, which times out with about 1 MiB
queued while the lane is stalled; the caller drops `Rest` and the
binary, and the socket process is closed: the owner's domain must then
hold no more of that binary's bytes than the busy limit and a piece,
by its binary allocator's count after a garbage collection of every
process that held it. The same owner domain is started with `+pad true`
among its emulator flags: its socket processes must report
`{async_dist, false}` from `process_info/2`, and the second
connection's bound must hold in it as in the others. A fifth test
domain stands in for a hostile network domain at the open: its grant
holds an open's answer while it pushes 10,000 grants of credit and
`{data, _}` messages to the named socket process, and while 10,000 of
its processes link to it and exit; the socket process must stop with
`econnaborted` at the first, it must keep no state from any of them
(its message queue is bounded only by the runtime's queue quota, which
the test sets and checks), and the open must answer
`{error, econnaborted}`. With an open socket, the owner calls the first
half of `controlling_process/2` and never the second while that domain
pushes data and credit without end: the socket process must hold no
more than its target, and a `send` waiting through the transfer must
meet its deadline. And a socket process started in a client domain
must be reachable from the grant's domain with `send` and `link`, by
`erx:exports/1`, before its open request is sent.
*Seeded failures:* a socket process started without
`{async_dist, false}` must, under `+pad true`, let the client's queue
pass the busy limit and a frame per process while the network domain
grants without draining, which shows the explicit option is what
keeps the outlet's refusal; a socket process that postpones messages
from the network domain in `opening`, or every push during a transfer,
must grow its message queue with the hostile domain's sends past the
test's bound; an `expose/2` that exports `[link]` alone must leave the
socket process linked to and never pushed to, its first `recv` waiting
past the test's deadline; one that exposes before it traps exits must
fail the unit test that traces a socket process's start and requires
`process_flag(trap_exit, true)` before `erx:export/3`; a socket process whose outlet sends without
`nosuspend` must leave the `send` unanswered and the owner's `close`
waiting past the test's deadline, which shows the refusing send is what
keeps it running; one that monitors its socket as it takes it must,
opened on a stalled lane, leave its owner's `close` waiting past the
test's deadline, which shows the link made from the network side is
what keeps the socket process from suspending at its start; a core that
keeps each refused grant of receive credit as a message of its own must
send the socket one grant per half target pushed once the lane drains,
not one; and a socket process that copies no piece cut from a larger
binary must hold the whole 100 MiB binary once the timed-out send's
caller has let it go.

**cowboy and ranch.** Once the web domain's front end exists
([design-web.md](design-web.md#the-network-front-end)), cowboy serves
HTTP requests and a WebSocket echo in the web domain over the stack, with
ranch's acceptors and cowboy's own `active_n`, unchanged. *Seeded
failure:* a socket process that never sends `{tcp_passive, S}` must stall
cowboy's connections once their count runs out.

### OTP's suites

`make check-oracle` runs OTP 29.1.2's `gen_tcp_api_SUITE`,
`gen_tcp_misc_SUITE`, `gen_tcp_echo_SUITE`, `gen_udp_SUITE` and
`inet_SUITE` on erXos and on stock on the host and compares them case by
case, and the `socket` suites, and `ssl` and `ssh` over the stack. On
erXos the suites run in a test domain and the stack in the network
domain, so every case crosses a lane through a socket process. An `erx`
socket is not a port, so the cases that branch on `is_port/1` take their
socket-backend branch on erXos and their port branch on stock, and
compare as passed against passed: `otp_7816` and the
`econnreset_after_async_send` cases among them, which check the send
results that **Send credit** in [The socket process](#the-socket-process)
chooses.

*Seeded failure:* a build whose `inet_backend` default is left at `inet`
must fail the suites on erXos, since no inet driver exists, which shows
the suites reach `erx_gen_tcp`; and a stub whose `controlling_process`
does not move the caller's queued socket messages to the new owner must
fail its cases.

### Floods and failure

On QEMU, against the targets of plan.md's network gates: SYN floods,
minimum-size frame floods, fragment floods, connection floods, router
advertisements from many sources, invalid frames, and frames with valid
checksums aimed at one client's established connection, at line rate,
while an established connection of another client and neighbour
resolution keep running. The tests check bounded memory in the network
domain, the other connection's progress, the reductions the flooded
client's sockets spend per period, measured by the test from outside the
account, staying within its share plus the overrun bound, and drop
counters by reason. Failure
tests kill the driver, an interface process, a connection, a grant and
the whole network domain under load, and check the survivors of
[Concurrency and failure](#concurrency-and-failure). Once RT8's queue
quota exists, a test network domain floods one socket process of a
client domain whose runtime sets one with messages of no protocol,
replies to no request and pushes past its credit: the socket must abort
at the first breach, the client domain's memory must stay within its
socket processes' targets and the quota, and a second socket of the same
client, to a well-behaved test peer, must still make progress once the
flood stops.

*Seeded failures:* the syncache bound removed must exceed the memory
bound under the SYN flood; credits disabled must let a connection's
mailbox exceed its bound under a junk flood to its four-tuple; the
router-list bound removed must grow the interface's memory under the
advertisement flood; the checksum verified before the credit check must
show in the interface's time per dropped frame under the flood to one
connection; a socket that charges no reductions must let the flooded
client's sockets spend past that bound; and the client's queue quota
unset must let its memory grow past that bound under the flood to its
socket process, which shows the quota is what bounds it.

### Build checks

Each with a test proving it catches a violation:

* only `erx_tcp_seq` does sequence-space wrap arithmetic;
* only `erx_net_bind` inserts into the demultiplexing table;
* only `erx_net_if` writes the configuration and neighbour tables, the
  hint count's increment by a transmitter and `erx_net_tables`'s
  deletion of a stopped interface's rows excepted;
* only `erx_net_tables` reads the configuration tables, so every reader
  gets them through its `configuration/0` and `snapshot/3`'s pid check;
* only `erx_net_credit` sends packet batches between stack processes;
* only `erx_net_clock` reads a clock or arms a timer in `erx_net`: no
  other module calls `erlang:monotonic_time`, `erlang:system_time`,
  `os:timestamp`, `erlang:start_timer`, `erlang:send_after` or the
  `timer` module, or writes a `receive ... after` with a timeout other
  than `infinity` or 0, and no module of `erx_net` or `erx_net_client`
  calls `gen_server:call/2`, `gen_statem:call/2` or `gen:call/3`, or a
  `call` of theirs whose timeout is not the literal `infinity`, so the
  virtual clock sees every wait but two kinds: a socket process's
  deadlines, a waiting recv's, of a connection or a datagram socket, and
  a waiting send's ([The socket process](#the-socket-process)), and the
  resolver loader's wait before it looks for a grant again, which no
  packet depends on ([Name resolution](#name-resolution));
* in `erx_gen_tcp` and `erx_gen_udp`, no function that the `gen_statem`
  callbacks of the socket process reach, by `xref`'s call graph, sends
  with `!` or `erlang:send`, links, monitors, demonitors or makes a
  call (`gen:call`, `gen_server:call`, `gen_statem:call`,
  `erx_inet:call`) but through `erx_sock_out`: its `send/2`, the
  refusing send to the socket; its `local/2`, a plain send to the owner
  or a caller; and its `watch/1`, the monitor of the owner. The last
  two refuse a pid of another node, so the socket process reaches
  another domain only through the refusing send. Replies to calls are
  `gen_statem`'s own, to callers of its own domain, since a call from
  another domain is an unknown message
  ([The socket process](#the-socket-process));
* in `erx_net_client`, only `erx_sock_out:start/2` starts an
  `erx_gen_tcp` or `erx_gen_udp` process, and it always passes
  `{spawn_opt, [{async_dist, false}]}`; no module of the application
  calls `process_flag(async_dist, _)` or passes `async_dist` elsewhere,
  so a socket process is refused at the busy limit in any runtime,
  whatever its `+pad` default
  ([The socket process](#the-socket-process));
* in `erx_net`, only `erx_net_admit:mint/2` admits a mint, and it
  refuses the system domain's id as a grantee
  ([The grant](#the-grant));
* in `erx_net` and `erx_net_client`, only `erx_net_admit` and
  `erx_sock_admit` match a tuple tagged `erx_origin`, so each side of
  the socket protocol takes the envelope off in one place; the source
  check of D18 ([design.md](design.md#chokepoint-checks)) covers OTP's
  modules and leaves erXos's applications to own their protocols, and
  this is that check for the stack's two;
* in `erx_net_client`, only `erx_inet` reads the application's `grant`
  key, so the grant's pid is known to `erx_inet:call/1` alone and every
  answer of the grant passes `erx_sock_admit`
  ([Untrusted input](#untrusted-input));
* no module a TCP payload passes through copies or joins it in Erlang
  outside the sites the fast path lists
  ([design-network-fastpath.md](design-network-fastpath.md#copies));
* only `erx_gen_tcp` and `erx_gen_udp` build a socket term
  `{'$inet', _, _}`, so no message the network domain sends has the shape
  of a stock socket message;
* a received segment, datagram or ICMP record is constructed only by its
  `*_wire` decoder; that the decoder checks the checksum before it
  decodes is not something a build check can see, and the decoders' fuzz
  targets with wrong sums and the interface's gate prove it
  ([Codecs: fuzz targets](#codecs-fuzz-targets));
* no module of `erx_net` calls `rand`, only `portable/erx_bytes` calls
  `crypto`, and only `erx_net_clock` calls `erx_bytes:entropy/1`, so
  every random key passes the clock's seam;
* the modules in `src/` of `erx_net` and `erx_net_client` call only
  modules of `erts`, `kernel`, `stdlib`, their own application and `erx_bytes`,
  which both builds provide; only `erxos/` (`erx_virtio_net`,
  `erx_net_erxos`, and the client's `erx_net_client_erxos`) calls a module of erXos's (`erx`, `erx_device`,
  `erx_facet` and the rest of the `erx` application) or its BIFs; and no
  `-include`, `-include_lib` or file name in the app's source reaches a
  path outside the app directory (N12);
* no `binary_to_atom`, `list_to_atom` or `binary_to_term` in `erx_net`;
* only `erx_netmap` calls `erx_netmap_nif`, and only `erx_netmap_nif.c`
  includes a netmap header or reads or writes netmap's mapping, every
  offset it uses coming from a plan of `erx_netmap_ring`'s; the check
  is that no other file of `c_src/` includes `<net/netmap.h>` and that
  `erx_netmap_nif.c` computes no address but through the core's plan
  types ([The netmap transport](#the-netmap-transport));
* every module whose header carries a FreeBSD notice is listed with the
  same files in `NOTICE-freebsd`, and the reverse.

## Scope

The stack this document designs has three parts. plan.md orders their
work; this document states what each is.

**The core,** which the sections above describe in full: Ethernet II;
ARP; IPv4 with reassembly, fragmentation on output and ICMP; IPv6 with
extension headers, reassembly, ICMPv6, neighbour discovery, duplicate
address detection, autoconfiguration with RFC 7217 identifiers and the
narrow MLDv2 listener; static configuration and DHCPv4; loopback; UDP;
TCP with the defaults of [Defaults kept](#defaults-kept); runs, their
cut in each transport's copy and the merge of received segments
([design-network-fastpath.md](design-network-fastpath.md)); the grant, its
limits and its account; `gen_tcp`, `gen_udp` and `inet`; the POSIX socket
protocol; the resolver operation; the port mapper; and every test of
[Verification](#verification).

**Extensions,** each a FreeBSD decision translated by the same rules and
behind the same processes, with no change to the core's structure:

* `socket` and `net` over an Erlang `prim_socket`
  ([The `socket` and `net` modules](#the-socket-and-net-modules));
* raw ICMP and ICMPv6 sockets for `ping`, translating the parts of
  `raw_ip.c` and `raw_ip6.c` that `ping` uses, each a datagram socket of
  the grant that receives the ICMP echo replies its identifier names:
  `erx_icmp_sock` for ICMP, which holds one identifier's demultiplexing
  key, so the identifier filter `ping` applies to its raw socket is the
  classifier's ([Classifying a frame](#classifying-a-frame)), and whose
  credit bounds the replies waiting for its owner;
* the device finishing what the copy finishes, a run's cut and a sent
  segment's delayed checksum, where virtio-net offers
  `VIRTIO_NET_F_CSUM` with `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`,
  behind the same requests
  ([Checksums in the copy](#checksums-in-the-copy),
  [design-network-fastpath.md](design-network-fastpath.md#device-segmentation));
* one interface process per receive queue on a device that hashes flows
  to several, so each flow still passes through one interface process
  and [Ordering](#ordering) holds;
* the TCP host cache, `erx_tcp_hostcache`, translating
  `tcp_hostcache.c`: a bounded table of path MTU, RTT and congestion
  values per destination, which one process owns and publishes, read by
  connections at their start and updated by a message from each at its
  end, as FreeBSD reads and updates its own;
* AccECN, FreeBSD's `tcp_do_ecn` modes 3 and 4 in `tcp_ecn.c`, translated
  and, as in FreeBSD, not the default;
* ICMP and ICMPv6 redirects, accepted as
  [IPv4 and ARP](#ipv4-and-arp) states;
* 802.1Q VLANs, translating `if_vlan.c`'s tag handling: a VLAN is an
  interface of its own whose driver is its parent's interface process;
* RFC 8981 temporary addresses, beside the stable ones, for outgoing
  connections where a program asks for them;
* multicast, `erx_mcast`, translating `in_mcast.c`, `igmp.c`,
  `in6_mcast.c` and `mld6.c`: group membership per socket, IGMPv3 and
  full MLDv2, and delivery to every member socket, each copy against that
  socket's credit.

**Outside the stack,** later, behind its seams: RACK-TLP as a loss
module; BBR as a congestion module,
with pacing in output; DCTCP as a congestion module over the ECN signal;
TCP Fast Open (`tcp_fastopen.c`); and TCP-MD5 signatures (RFC 2385),
whose option `erx_tcp_wire` records so that the syncache refuses a signed
segment as FreeBSD refuses it for a listener without TCP-MD5 (`syncache_add`, `syncache_expand`).
None of them is designed here, and none needs a change outside the seams
it plugs into, except pacing, which BBR brings.

## Decisions

These are settled. One question remains open
([Open decisions](#open-decisions)).

1. **The grant's account covers its sockets.** Every reduction a grant's
   sockets spend, on requests and on packets, is charged to the grant's
   account, and socket processes' requests go straight to the sockets,
   which run the facet's generated admission path
   ([The grant's account](#sockets-act-for-one-domain)). This extends the
   facet mechanism, whose account otherwise covers the facet's own work
   and the work of the requests it forwards. The alternative, routing
   every socket request through the grant, costs two more local hops per
   call and still leaves packet-driven work, which has no request,
   unaccounted.
2. **RFC 7217 stable interface identifiers,** with a secret the system
   keeps across boots, one of the vault's machine keys, used through a
   key facet so that it never enters the network domain
   ([IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)).
   FreeBSD's default derives SLAAC addresses from the MAC address
   (EUI-64), which lets anyone who sees an IPv6 address track the
   machine across networks; RFC 8064 recommends RFC 7217, and FreeBSD 15
   implements it with the setting off. The departure from FreeBSD's
   default is made for privacy; the identifier is stable only if the
   secret is, so the secret is kept with the machine's other keys, and a
   fresh installation makes it afresh, as it does the SSH host key.
3. **DHCPv4 is part of the core,**
   ([Addresses and routes](#addresses-and-routes)), written from RFC
   2131 and RFC 2132 with FreeBSD's `dhclient` as the behavioural
   reference. QEMU's user network and most home networks hand out IPv4
   addresses by DHCP, so a Raspberry Pi on a LAN needs it.
4. **Remote distribution in release builds runs only over the TLS
   carrier**
   ([Distribution to other machines](#distribution-to-other-machines)).
   OTP's plain TCP carrier authenticates by an MD5 challenge over a
   shared cookie and sends everything unencrypted; its TLS carrier
   authenticates both nodes by certificate and encrypts. Development
   builds allow both, since they run trusted code only.
5. **`socket` comes after `gen_tcp`.** The `socket` module answers
   `enotsup` until its extension lands, a documented difference with a
   test, and OTP's socket suites are expected failures meanwhile; plan.md
   schedules the extension. `gen_tcp`, `gen_udp`, `ssl`, `ssh` and
   distribution do not use `socket`, so nothing the system needs waits on
   it.
6. **Packet modes are framed in the socket process,** in the owner's
   domain, with ERTS's C `decode_packet`, as stock frames them in its
   inet driver ([The backend](#the-backend)). The framing must sit where
   the unpresented bytes are: a socket that pushes ahead within its
   credit has bytes in the socket process that a change of packet mode
   must still frame, as an HTTP server's switch from `http_bin` to `raw`
   needs. The parser gets a fuzz target over every mode offered, and
   runs on peer data only in the domain that reads it, as on stock in
   the node that reads it, so no client's framing runs in the network
   domain.
7. **RACK is deferred.** The default stack is the reference, and
   RACK-TLP and BBR come later behind the seams
   ([Why FreeBSD's default stack](#why-freebsds-default-stack)).
   RACK-TLP is a second TCP implementation in FreeBSD, with its own input
   path and the high-precision timer system; the send log keeps it cheap
   to add as a loss module when its value is measured.
8. **The packet-script and interop oracle is FreeBSD 16.** The FreeBSD
   test host, 16.0-CURRENT, and its vnet jails are the oracle for
   the packet scripts and for traffic; the stack keeps no FreeBSD guest.
   Since the host tracks -CURRENT, every verdict record names its kernel
   ([Packet scripts against FreeBSD](#packet-scripts-against-freebsd)).
   QEMU is not installed there, so the host runs reach its tap devices
   through the tap transport, and the stack runs on the host's own OTP
   ([The driver](#the-driver)).
9. **The translation follows FreeBSD 16 at commit `975e3605ebb1`**
   (`main-n285245`), the kernel of the test host, for its more recent
   changes and so that the stack and its oracle are one FreeBSD. What
   was translated from `release/15.1.0-p6` is not translated again: the
   aim is a stack that works and interoperates, not one
   equivalent to FreeBSD line by line. Of the changes between the
   release and the pin, those the wire or an interoperating peer can
   see and the fixes of real bugs are ported, each recorded with its
   FreeBSD commit in `NOTICE-freebsd`
   ([Provenance and notices](#provenance-and-notices)).
10. **`erx_net_admit` is hand-written until the schema generator
    exists,** with the generated module's exact signature, a stopgap in
    `TODO.md` deleted when the generator over `abi/services` lands. Until
    `erx_facet` exists, a grant on a host runs under `erx_net_local`'s
    loop, which
    calls the same admission path, so the host route does not wait for
    either.
11. **The stack is a package of its own.** The aim:
    "ideally we'd even structure our network stack as a separate package
    that can be used independently from erXos e.g. with tap/tun or
    netmap/dpdk/f-stack/etc/whatever is on linux", and "We might even
    release it separately at some point". The four seams of
    [The effect layer](#the-effect-layer) are already where erXos meets
    the stack, so the package costs a portable implementation of each,
    a source layout by seam, a build check, and the client backends in
    an application of their own (N12).
12. **The client backends are an application of their own.**
    `erx_gen_tcp`, `erx_gen_udp` and `erx_inet` live in `erx_net_client`,
    which every domain's image carries beside `erx`, so a client domain
    carries the backends and their socket processes instead of the
    stack, and a release of the package is the two applications.
13. **Every socket has a socket process in its owner's domain,** a
    `gen_statem` of the same shape as stock OTP's `gen_tcp_socket`
    ([The socket process](#the-socket-process)). It alone talks to the
    socket in the network domain, sending every request and taking every
    push, and it takes the envelope off each push after checking that
    it comes from the domain the socket was opened against, then gives
    its owner the stock messages. One mailbox and one lane carry
    everything between a socket and its program, so the ordering of
    replies and deliveries, `controlling_process` and the owner's exit
    follow without a rule of their own, and the universal envelope of
    [design-domains.md](design-domains.md#the-peer) keeps no exception.
14. **A domain that holds `net` runs at or above the socket protocol's
    floors** for the three limits the funnel applies to a frame:
    `max_frame`, `max_message_heap` and `funnel_depth`, each computed per
    operation from the protocol's schema, since a dropped push would
    hang its socket for good and a dropped reply its caller, whichever
    limit dropped it. The floors are in design-domains' table of limits
    ([design-domains.md](design-domains.md#principals-sessions-and-quotas))
    and bind no other domain; the system domain never holds `net`
    ([The grant](#the-grant)). The client checks its own three values
    before it sends an operation's request, and answers an operation it
    could not carry `{error, enobufs}` itself, with one line in its log
    ([Message sizes](#message-sizes)), so a misconfigured domain fails
    loudly at its first use of what it cannot carry instead of hanging,
    and no refusal travels back through the limit that caused it; the
    network domain's own limits meet the floors through the system
    manifest's check.
15. **A raising connection step ends the connection.** A socket whose
    step raises ends itself from its state before the event, sends a
    RST, pushes `{error, econnaborted}` and exits with the exception
    ([What fails and what survives](#what-fails-and-what-survives)); it
    never counts the raise and goes on with the state it had, since a
    bug in one flow's state is not worth keeping alive. A step that
    raises over a batch of drained messages ends the connection the same
    way ([design-network-fastpath.md](design-network-fastpath.md#one-step-per-mailbox)).
16. **A socket within one domain keeps its socket process.** The owner
    declined a path that drops it when a grant's grantee is `local`, as
    on a development host and wherever `erx_net` runs without erXos
    (N12): there no envelope is taken off and the owner's domain is the
    network domain, so the connection or datagram socket could hold the
    client half itself, as stock's port does, running `erx_gen_tcp_core`
    or `erx_gen_udp_core` beside its own step. The measurement of
    [the caller holding the socket](#alternatives-considered) bounds the
    gain from above, 12.9% more transactions a second and 16.7% less CPU
    per transaction at one scheduler; the cost is a second effect shell
    around each presentation core, the connection carrying the client
    half's duties in one configuration only, and host runs (N11) that
    would not exercise the socket protocol between processes, the shape
    every erXos socket has. In the same runs, with the socket process
    removed and the window update also taken off the step, the
    connection was still 62% of the profile, two steps of about 275
    Erlang calls each, against 164 for the interface and 69 for the
    driver, so the connection's fixed cost per step is the larger lever,
    and every configuration pays it. The question is reopened only when
    the hack's numbers, measured on a standalone release of `erx_net`,
    where every socket is within one domain, show the gain worth the
    second configuration.
17. **The client half stays Erlang.** The owner declined an ERTS object
    in the owner's runtime, shaped as stock's inet port, which would
    remove the socket process's hop in every mode and configuration:
    callers would reach it in their own scheduling with no message, the
    funnel would deliver the connection's pushes to it, and it would
    send the owner stock's messages. It costs a presentation core in C
    on the path of untrusted pushes, with its fuzz target, a new kind of
    delivery target for the funnel, and a C entry on D18's list of
    protocol owners, where the socket process is ordinary Erlang under
    the existing rules. The question is reopened only when a measurement
    with the owner in another domain on erXos shows the owner's side of
    a socket among the larger costs of a transaction, beside the lane
    crossings and the connection's own steps; the watch list holds that
    measurement ([todo-performance.md](todo-performance.md)).
18. **The socket process sends through a refusing send, not past the
    busy limit.** It sends to its socket only with `erlang:send/3` and
    `[nosuspend, notify]`, through `erx_sock_out`; a refused message
    stays where it already waited, and the runtime tells the process
    when to try again ([The socket process](#the-socket-process)). So the
    client's queue for the network domain is the queue every peer gets,
    the busy limit and a frame per sending process (D12 of
    [design-domains.md](design-domains.md#invariants)), whatever the
    network domain grants or pushes, and the property rests on one
    module that a build check makes the only site. The rejected
    alternative is stock OTP's `async_dist` flag with marks: the flag
    lets a process queue past the busy limit without suspending, which
    keeps it live but bounds nothing, and marks bound the stream's bytes
    by a reference the connection answers as it takes them. Marks bound
    only what they cover: receive credit messages and the calls that
    forged replies to a predictable `N` let through would each need a
    bound of its own, and each new kind of message another. The refusing
    send bounds every message the socket process sends with the one
    bound ERTS already keeps, and needs none of the marks' state: a
    reference, an offset and a gate in the socket process, a count
    between marks in the connection and two protocol messages. It costs
    one ERTS change, the notification, which the bell of
    [design-runtime.md](design-runtime.md#connections-in-erts) measures
    against first. The objection that a send option rests on every send
    site using it is met by the build check that no site in the socket
    process's modules sends but the outlet; the objection that a
    runtime's `+pad` default would give the socket process the flag
    anyway is met by the outlet's start, which spawns it with
    `{async_dist, false}`, and the build check that nothing else starts
    it or sets the flag.
19. **The system domain never holds the grant.** The trusted base parses no network traffic, the manifest check
    refuses a `net` grant to the system domain, and whatever in the
    system domain would need the network moves to a service domain;
    root's session holds `net`, so the network utilities and root's
    programs run there ([The grant](#the-grant)). The socket protocol
    therefore meets one queue rule on the client's side, the busy limit
    of an ordinary domain, and needs none of the system domain's: no
    stream piece, credit or exit of a socket ever waits behind
    `system_queue`, where a plain message past it is dropped and any
    other signal ends the destination domain.

### Open decisions

1. **Which client domains run with a queue quota.** What a socket
   process has not yet taken from a hostile network domain is bounded
   only by its runtime's queue quota
   ([Untrusted input](#untrusted-input)), and design-runtime leaves
   `-erx queue_quota` unset by default, as stock OTP has none. The
   recommendation: the domain service gives every domain it grants `net`
   a quota of 1 MiB unless its specification names one. Only the
   processes another domain may message have frames to count, and in
   such a domain those are its socket processes, `erx_inet`'s loader and
   the aliases of its calls, so the quota bounds exactly what the network
   domain can reach, and a correct network domain meets it only when a
   socket process falls behind, which pauses its lane and loses nothing.
   The alternatives are a default quota for every domain, one rule but a
   change to design-runtime's default for domains that talk to no other
   service, and a quota each socket process sets on itself, which needs a
   new runtime call.
2. **Whether the bar on the system domain covers `netadmin` too.**
   Decision 19 bars the `net` grant. `netadmin` carries no socket and no
   packet, but its answers, every client's statistics and the
   interfaces' state, are built by the domain that parses the network's
   traffic, and nothing in the system domain configures interfaces, which
   the network domain's manifest arguments set. The recommendation:
   property 15 refuses every facet of the network service to the system
   domain, `net` and `netadmin` alike, so the rule reads "the system
   domain holds nothing the network domain serves", and administrators
   use `netadmin` from their sessions. It costs nothing today; the
   alternative keeps `netadmin` available to the system shell for an
   operator whose only line is the system shell's.

## Alternatives considered

**Port FreeBSD's structure line by line.** It would keep `tcp_do_segment`
as one function and carry locking and mbuf idioms into code that has
neither, so a reader would have to recognise which lines mean nothing in
Erlang. Translating decisions keeps everything the wire can see and
drops the rest.

**aloha as the base.** Rejected: its process structure, its effect-mixed
connection code and its codec would all be rewritten, and those are most
of it ([What a naive Erlang stack gets wrong](#what-a-naive-erlang-stack-gets-wrong)).

**RACK first.** RACK is a second TCP implementation of 24,673 lines that
needs the high-precision timer system and its own input path before the
system sends a byte. It is deferred ([Decisions](#decisions), 7);
the send log keeps it cheap to add later as a loss module.

**A process per layer.** Each layer would add a mailbox trip per packet
and serialise all connections through each layer's process; the
interface process decodes all layers in one pass.

**Deliveries straight to the owner, unwrapped by the runtime.** The
connection would send `{tcp, S, Data}` to the owner itself, and the
peer's envelope (edit 16 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos)) would
make an exception for socket messages whose socket pid is of the lane's
domain. It saves the local hop but puts a list of message shapes into
the runtime, gives D18 an exception, and leaves `controlling_process` a
round trip to the network domain.

**A relay for deliveries alone.** A process in the owner's domain would
take the envelope off pushes while `recv` and `setopts` replies came
back to the caller directly. The two paths are two senders, so the owner
could see later bytes before earlier ones, a reply to `{active, false}`
could overtake deliveries sent before it, and moving the socket to a new
owner would have to coordinate both. One process for everything keeps
the order of one mailbox and one lane.

**Presentation in the connection, the socket process forwarding.** The
socket process would only forward requests and unwrap pushes, and the
connection would keep active modes, framing and `recv` as stock's inet
driver keeps them. Every `setopts` of active mode, every re-arm of
`{active, once}` and every passive `recv` would cross the lane twice, and
a change of packet mode could not reach bytes already pushed. Within one
domain, where nothing crosses a lane and no envelope is taken off, the
connection holding the client half is the sixteenth of the
[Decisions](#decisions), declined until measured.

**The caller holds the socket.** After the connect, the caller would
take the connection over from its socket process: it would send its
requests and credit itself and take the pushes in its own mailbox, with
the bytes it holds and the credit it granted kept in its own process. A
throwaway change did this for the network bench's request-reply worker
alone, within one domain: on the FreeBSD x86-64 test host, natively on
stock OTP 29 (erts 17.1, JIT), `+S 1:1`, rr-64 over the tap transport to
a jail, five interleaved rounds, medians against erXos 07c84450, it
measured 16,460 transactions a second against 14,576 (12.9% more) and
46.4 us of CPU per transaction against 55.7 (16.7% less), with four
messages and about four process schedules fewer per transaction, about
2.3 us each; bulk send and receive stayed within noise
(`~/erxos-history`, `net-rrhacks-2026-11-10`, commit 4b7dbfb). It cannot
keep stock's API. A second process's `send` or `recv` would find the
socket's state in a process that serves no calls; pushes would reach
the owner's mailbox while it is not in a socket call, where a
`gen_server` owner's `handle_info` takes them; and across domains active
mode still needs a process of the owner's domain that takes the
envelope off. Holding the socket in the caller only while that is safe
would make the socket's home move with what each process does, and no
process can move it back out of an owner that is not in a socket call.
The measurement is the upper bound of removing the socket process
within one domain, which the sixteenth of the [Decisions](#decisions)
weighs.

**Sends straight from any caller to the connection.** OTP's own
`gen_tcp_socket` sends from the caller's process straight into the
socket (`gen_tcp_socket.erl:557-582`) and receives through its server,
FreeBSD's split of `so_snd` from `so_rcv`. Here a send that does not
fit the send buffer would wait in the network domain, holding a piece
there for each sending process the client has, or would stop the
connection taking messages and pause the client's whole lane behind one
slow peer; the pieces of two large sends from two callers would need a
lock in the connection to stay whole; and every caller would monitor the
connection for each call, a control record each way across the lane.
Callers could take send credit before they send, but one connection's
credit shared by every process that sends on it needs a party that
hands it out and orders the sends, which is the socket process again.
Send credit takes the send's reply off the lane with the socket process
still the one sender.

**Framing in the connection.** The connection would frame the stream
with `decode_packet` and push only whole packets, while active modes and
`recv` stayed in the socket process. Since the connection pushes ahead
of what is presented, a change of packet mode would come after the bytes
it should apply to were framed, each `setopts` that changes a packet
option would cross the lane, and `decode_packet` would run in the
network domain on every client's peer data
([Decisions](#decisions), 6).

**Every request through a facet in the system domain.** The client's
facet would forward each `send` to the network domain and relay each
reply: two more crossings per call, and packet work would still be
unaccounted. The grant runs in the network domain, as the storage
services' grants run in theirs ([design-files.md](design-files.md)).

**A reply to every piece sent.** The connection would answer each
`{send, Piece}` once the piece is in its send buffer, later while the
buffer is full, and the socket process would send the next piece only
after that reply. It costs a lane round trip per piece, one more
message on every request-reply exchange, and a waiting writer in the
TCP core that FreeBSD keeps in its socket layer; send credit answers
the same question, whether the buffer has room, before the bytes leave
the owner's domain.

**Queuing past the busy limit.** Stock OTP's `async_dist` flag, or a
flag of erXos's own, would let the socket process send past the busy
limit and never suspend, and its protocol would then have to bound
what it queues: marks do so for the stream's bytes, and every other
kind of message would need a bound of its own ([Decisions](#decisions),
18). The refusing send keeps the one bound every sender has.

**The socket process monitoring its socket.** A monitor, a link or a
demonitor towards a busy domain suspends its caller after queuing the
signal, so a socket process that made its own would suspend at its
start on a stalled lane. Its socket links to it instead, from the
network side, so the socket needs no monitor of it either: one link
carries both ends.

**The socket process calling the grant.** The open would then be a call
the outlet had to carry, with a monitor of the grant that suspends as
above. The opener makes the call, a plain one that may hold only the
opener, and hands the socket over as an accepting listener's socket
process does.

**Modular sequence arithmetic, checked by types.** An opaque `seq()` type
lets Dialyzer report arithmetic on sequence numbers outside their module,
but not comparisons, which are where wrap bugs live. Lifting removes the
modular comparisons instead of guarding them.

**Random bytes in the context.** The loop would draw some bytes before
every step and pass them in. The loop cannot know how many a step needs
without a list of which events draw what, a step given too few would
need a rule for running out, and a draw before every step is a kernel
call per segment batch, almost always unused. A generator in the state
has none of these: it never runs out and costs nothing until a step
draws.

**An unverified segment type.** `classify/2` could decode the whole
transport header into a record marked unverified, which `verify/1`
would turn into a verified one. Every field of the unverified record
would then be readable before its checksum, and the rule that only the
lookup reads them would rest on every reader remembering it. With the
transport header decoded only after the checksum, there is no such
record to read.

**One Erlang timer per FreeBSD timer.** Five timers per connection, each
cancelled and restarted on most ACKs, and a stale-message check for each.
FreeBSD 15 itself moved to one callout over an array of deadlines.

**The syncache in the listener.** The interface would send every SYN to
the listener, and a flood would fill the listener's mailbox; with cookies
computed in the interface for overflow, two places would answer SYNs.
FreeBSD handles SYNs in the input path, and so does the stack.

**Linux as the reference.** Linux's stack is the more common peer and
stays an interoperability oracle, but erXos follows FreeBSD where UNIX
systems differ, and FreeBSD's code can be translated under its licence.

**Drop a frame when the device's queue is full.** The driver would
drop and count the frame, as the receive side drops a refused batch,
and the backlog and the `writable` event would go. Every burst longer
than the device's ring would then be loss the sender caused itself,
which FreeBSD's send queue in front of the ring does not have, and TCP
would cut its window for it ([The driver](#the-driver)).

**A QEMU hub for tap devices on the FreeBSD host,** as slirp is reached
on macOS. It needs an emulator on a test host that runs none; the tap
transport is the netmap transport's construction over a file
descriptor, and serves a node outside erXos as well
([The tap transport](#the-tap-transport)).

**A netmap port program, or slots lent to binaries.** A helper relaying
netmap's rings through a pipe adds two copies per frame and an
uncredited mailbox; binaries over ring slots save the receive copy but
let one held segment stop a ring that returns its slots in order. Both
are weighed in [The netmap transport](#the-netmap-transport).

**lwIP behind a NIF.** A C stack in the domain that parses hostile
packets, whose numbers would decide nothing about an Erlang stack. The
stack has no stopgap.

**A sum carried with the send buffer.** The payload's sum could be
computed where the owner's bytes first arrive and kept beside each of
the send buffer's binaries, with the header's checksum filled from it.
But output cuts segments at offsets the owner's writes never chose, and
the cut changes from one transmission of the same bytes to the next.
The sum of a cut is the sum of whole binaries plus the sums of partial
ones, and computing a partial one reads its bytes. So the buffer would
carry sums that each segment still has to correct by reading. Finishing
the checksum at the last copy needs no stored sum and reads each byte
once whatever the cut, as FreeBSD's delayed checksum does
([Checksums in the copy](#checksums-in-the-copy)).

**Device offload alone.** It removes the checksum only where a device
offers it: not on the harness's hub port, not on a netmap port, and not
on every board. Elsewhere it leaves the two passes. The copy's sum
works on every medium that is copied in C, and offload fits behind the
same request.

**A verdict from the copy.** A copy that checked the TCP checksum would
have to find the IP header's length, the protocol and the addresses,
which is parsing in C what the decoders parse in Erlang. A sum from a
fixed offset needs none of that, and the stack derives every layer's
sum from it.

**Receive offload (`GUEST_CSUM`).** It saves only the additions the copy
makes anyway. It also brings frames whose checksum is a claim, or is
missing, into a stack that otherwise believes nothing a device says
([Checksums in the copy](#checksums-in-the-copy)).

## References

* FreeBSD src, main commit `975e3605ebb1` (16.0-CURRENT, `main-n285245`),
  the pin; and `release/15.1.0-p6`, commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, the tree the translation
  and this document's line references were read from: `sys/netinet`,
  `sys/netinet6`, `sys/net`, `sys/netinet/cc`, `sys/netinet/tcp_stacks`.
* FreeBSD tcp-testsuite, https://github.com/freebsd-net/tcp-testsuite;
  packetdrill (nplab), https://github.com/nplab/packetdrill.
* N. Cardwell et al., "packetdrill: Scriptable Network Stack Testing,
  from Sockets to Packets", USENIX ATC 2013.
* RFC 9293 (TCP), RFC 5961 (blind in-window attacks), RFC 6528 (initial
  sequence numbers), RFC 7323 (window scaling, timestamps, PAWS), RFC
  2018 and RFC 6675 (SACK and SACK-based recovery), RFC 6937 (PRR), RFC
  3042 (limited transmit), RFC 6928 (initial window), RFC 5681 and RFC
  6582 (congestion control, NewReno), RFC 9438 (CUBIC), RFC 3168 (ECN),
  RFC 6298 (RTO), RFC 1337 and RFC 6191 (TIME-WAIT), RFC 5927 (ICMP
  attacks), RFC 8985 (RACK-TLP).
* RFC 791, RFC 826, RFC 792, RFC 1191, RFC 1071 and RFC 1624 (checksum);
  RFC 8200, RFC 5095, RFC 5722, RFC 7112, RFC 4443, RFC 4861, RFC 4862,
  RFC 3810, RFC 6724, RFC 7217, RFC 8064, RFC 8106, RFC 8201, RFC 8981;
  RFC 6864 (IPv4 identification); RFC 768; RFC 2131 and RFC 2132.
* J.-P. Aumasson and D. J. Bernstein, "SipHash: a fast short-input PRF",
  INDOCRYPT 2012.
* aloha, https://github.com/yamt/aloha, commit `0aa96f14`.
* The research records this design rests on:
  [the mapping of FreeBSD's stack to Erlang](research-freebsd-net-mapping.md)
  and [the assessment of aloha](research-aloha.md).
* pkt, https://github.com/msantos/pkt.
* Erlang/OTP 29.1.2: `lib/kernel/src/gen_tcp.erl`, `inet.erl`,
  `gen_tcp_socket.erl`, `erl_epmd.erl`.
