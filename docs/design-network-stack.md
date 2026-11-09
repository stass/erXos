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
  decision comes from FreeBSD 15.1 (tag `release/15.1.0-p6`, commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`) and its default TCP stack,
  the function block named "freebsd", with CUBIC as the default
  congestion control. Each Erlang function that translates a FreeBSD
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
* **A connection is the socket.** A program's `gen_tcp` calls go to the
  connection process directly, across one lane; the interface process
  hands it segments, one local message per batch of frames. There is no
  socket process apart from the connection and no process per layer.
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
  stack is the reference, by the owner's decision; RACK-TLP and BBR are
  left for later, each a module behind these seams.
* **C does only per-byte work:** the Internet checksum and the SipHash
  keyed hash, both per-byte primitives of the runtime. Whether TCP's
  established path needs native code is measured on this stack, on
  erXos's kernel.

## Contents

1. [Context](#context)
2. [Requirements](#requirements)
3. [The construction](#the-construction)
4. [Processes and the packet path](#processes-and-the-packet-path)
5. [The TCP core](#the-tcp-core)
6. [IP, neighbours and UDP](#ip-neighbours-and-udp)
7. [Modules and provenance](#modules-and-provenance)
8. [Authority and admission](#authority-and-admission)
9. [The interface towards Erlang programs](#the-interface-towards-erlang-programs)
10. [The interface towards POSIX programs](#the-interface-towards-posix-programs)
11. [Untrusted input](#untrusted-input)
12. [Concurrency and failure](#concurrency-and-failure)
13. [Refusals and error results](#refusals-and-error-results)
14. [Where C is used, and what is measured](#where-c-is-used-and-what-is-measured)
15. [Verification](#verification)
16. [Scope](#scope)
17. [Decisions](#decisions)
18. [Alternatives considered](#alternatives-considered)
19. [References](#references)

## Context

### What the stack matches

Three things fix the stack's behaviour.

* **The protocols, as FreeBSD 15.1 implements them.** The owner chose to
  "take freebsd stack as a reference and translate logic to erlang ... so
  we don't discover problems from scratch", and agreed to translate
  FreeBSD's decisions, not its structure, against one pinned release.
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
decisions. The owner decided to defer RACK: the default stack is the
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
| a payload copied four times on transmit, checksum in Erlang | headers and payload kept apart until the device NIF's one copy; checksum in C |
| unbounded neighbour cache and pending queue, unsolicited replies accepted | bounded neighbour tables in the interface process, FreeBSD's acceptance rules |

### What exists today

* No part of the stack is in the tree: `erlang/apps` holds no network
  application, and no client of a network service exists in any domain.
* No Erlang code can read the kernel's entropy generator: the
  runtimes call `erx_entropy_read` for musl and for ERTS's reference key
  ([design-runtime.md](design-runtime.md#unguessable-references)), and
  `erx_bytes:entropy/1`, Erlang's entry to it, is specified
  ([design-runtime.md](design-runtime.md#per-byte-primitives),
  [design.md](design.md#decisions)) but not written. The host link's
  session identifiers wait on the same entry (`TODO.md`).
* The per-byte primitives the stack uses, `erx_bytes:inet_csum/2`,
  `inet_csum_update/3` and `siphash24/2`, are written
  ([design-runtime.md](design-runtime.md#per-byte-primitives)), as
  statically linked NIFs in portable C.
* The device NIF is specified: `erx_device:post/4` takes one to four
  binary segments of one request and copies them into a pool buffer, and
  `erx_device:complete/2` returns up to 64 KiB of completed buffers as
  fresh binaries per call
  ([design-runtime.md](design-runtime.md#the-device-nif)).
* OTP's kernel already has the seam a new socket backend needs. `gen_tcp`,
  `gen_udp` and `inet` dispatch every call on a socket of the form
  `{'$inet', Module, Handle}` to `Module`
  (`otp/lib/kernel/src/gen_tcp.erl:261`, `otp/lib/kernel/src/inet.erl:469`),
  and `inet:gen_tcp_module/2` and `inet:gen_udp_module/2` choose the module
  from the `inet_backend` setting (`inet.erl:3289`, `inet.erl:3410`).
* The runtime drops OTP's `socket` and `net` NIFs, and `gen_tcp:listen`
  answers `{error, eprotonosupport}` from `prim_inet` (`TODO.md`).

## Requirements

* **N1. Behaviour.** On the wire, the stack behaves as FreeBSD 15.1's
  default stack with its default settings, except where this document
  states a departure; every difference found by the oracles is a bug, a
  documented departure with a test, or a FreeBSD bug recorded as such.
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
  receive and once on transmit, both in the device NIF.
* **N8. Functional core.** Every protocol decision is a pure function,
  tested on the host, and protocol state machines are explored
  exhaustively over an abstract alphabet to a stated depth.
* **N9. Seams.** Loss detection and congestion control are replaceable
  per connection without touching the connection's other code.
* **N10. Provenance.** Every module that translates FreeBSD code carries
  the FreeBSD files' copyright notices and licence, and names the
  functions it translates, at the pinned commit.

## The construction

The stack rests on four rules. Each removes a class of mechanism that
FreeBSD or a naive Erlang stack needs, and the rest of the document
follows from them.

### One owner, one step

Every piece of protocol state belongs to exactly one process:

| Owner | Process | State it owns |
| --- | --- | --- |
| an interface | `erx_net_if`, one per network interface | its addresses, its neighbour cache (ARP and IPv6 neighbour discovery) and the packets waiting on it, its routers and prefixes, its IP reassembly queues, its share of the syncache, its rate limiters |
| a TCP connection | `erx_tcp_conn` | the connection's control block (FreeBSD's `struct tcpcb`), its send and receive buffers, its reassembly queue, its owner |
| a listening socket | `erx_tcp_listen` | its accept queue and its waiting `accept` callers |
| a UDP socket | `erx_udp_sock` | its receive queue, its options, its owner |
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
16-byte key with `erx_bytes:entropy/1`, the network domain's one call
into the kernel's generator (`erx_entropy_read`,
[design-kernel.md](design-kernel.md#interrupts-time-and-entropy)), in
its initialisation. Every owner the stack spawns (a connection, a
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
every step the process makes sure one `erlang:start_timer/3` is
outstanding no later than that deadline: it starts one when none is
outstanding or the deadline is earlier than the outstanding one, and
otherwise leaves the outstanding one, which may then fire early. When a
timer message arrives, the process calls `step({expired, Now}, ...)`,
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

* The receiver creates an `atomics` counter and publishes it with its pid:
  the driver in its interface record, a connection or socket in its
  demultiplexing entry, and an interface two counters in its interface
  record, one for its driver's batches and one for what senders hand it.
* A sender adds the units it is about to send (frames, segments or
  bytes, as the receiver chose) with `atomics:add_get/3`. If the result
  exceeds the receiver's limit, it subtracts them again and does not send.
* The receiver subtracts the units of each message it takes.
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
erx_net_sup  (rest_for_one)
 |- erx_net_tables          ETS tables, secrets, port-mapper names;
 |                          monitors each interface, deletes its rows
 |- erx_net_if_sup  (one_for_one)
 |   |- link supervisor per interface  (rest_for_one)
 |       |- the driver       erx_virtio_net, or erx_net_loop for loopback
 |       |- erx_net_if       the interface process
 |       |- erx_dhcp4        when the interface is configured for DHCP
 |- erx_net_grant_sup  (simple_one_for_one, temporary children)
 |   |- erx_net_grant        one per client domain; traps exits
 |       ~ linked, not supervised: erx_tcp_conn, erx_tcp_listen,
 |         erx_udp_sock, each acting for that grant's domain alone
 |- erx_epmd                the port mapper for exposed domains
```

`erx_net_tables` owns the shared ETS tables, so a crash of any other
process loses no table; the `rest_for_one` strategy restarts everything
after it when it fails, since every socket's entries live in its tables.
A driver restart resets its device
([design-runtime.md](design-runtime.md#the-device-nif)) and restarts its
interface process, which loses only soft state: neighbour entries,
reassembly queues and half-open handshakes, which peers retransmit. The
rows a stopped interface published go with it
([What owners publish](#what-owners-publish)).

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
| `erx_net_ifs` | one per interface: its name; its pid, which every other row it writes names; its two credits, one for its driver's receive batches and one for what senders hand it; its driver's pid and credit; its link (`ethernet`, or `none` for loopback); its link-layer address; its MTU; its IPv6 link MTU; and its IPv6 hop limit | the interface | every sender; every interface's view |
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
   driver's interrupt message makes it call `erx_device:complete/2`, which
   copies up to 64 KiB of completed frames into fresh binaries: the one
   per-byte copy of the receive path. The driver strips the device's own
   header (virtio's `virtio_net_hdr`) and sends the batch to the interface
   process in one message, against the interface's receive credit. The driver
   parses nothing else, as sDDF's split of driver and protocol prescribes
   ([design.md](design.md#drivers-and-dma)).
2. **Interface: classify, reserve, complete.** For each frame the
   interface process runs two pure functions of `erx_net_input` around
   one effect:
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
   for TCP, UDP, ICMP and ICMPv6 the checksum first, with
   `erx_bytes:inet_csum/2` (a read pass, no copy), then the header and
   options. A frame that fails gives its unit or token back and is
   dropped. So the checksum, the one cost that grows with a frame's
   length, is spent only on a frame something has room for, and a
   frame dropped for want of room costs a header decode and one lookup,
   whoever it names. A frame that holds room and then fails its checksum
   costs the checksum as well, and because it gives its unit or token
   back, neither credit nor the ingress bucket bounds that work: frames
   with bad checksums are checksummed at the rate the link delivers
   them, as FreeBSD checksums every frame it receives.
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
   so nothing is copied.
4. **Connection.** The connection folds `erx_tcp:step/3` over the
   segments, one at a time, exactly as FreeBSD processes one segment at a
   time, collecting the actions. It then sends all frames the steps
   produced (ACKs, data) to the driver in one message, delivers all
   in-order data in one message to the owner, replies to waiting callers
   and re-arms its timer.
5. **Connection to owner.** In active mode the delivery is
   `{tcp, Socket, Data}` sent to the owner in domain D: a frame on the
   lane from the network domain to D, decoded by D's funnel.

### Classifying a frame

`erx_net_input` is the receive decision of FreeBSD's `ether_demux`,
`ip_input`, `ip6_input` and the pcb lookups of `tcp_input_with_port`,
`udp_input` and the protocols' ICMP handlers, taken as far as choosing
where a frame goes and no further. Its input is a frame from the driver,
`{frame, Bytes}`; on the loopback interface, an IP packet with the zone
its sender's path gave it, `{frame, Zone, Bytes}` ([Loopback](#loopback));
or a datagram reassembly rebuilt, `{reassembled, Family, Zone, LinkCast,
Bytes}`. Its view is a map:

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

1. **Owner to connection.** `gen_tcp:send/2` in D sends `{send, Data}` to
   the connection with a reply alias: a frame on the lane, decoded by the
   network domain's funnel into a binary of the network domain.
2. **Connection.** The step appends the binary to the send buffer, a queue
   of binaries, and runs output. Each segment's payload is a sub-binary
   of the buffer. The connection encodes the TCP, IP and link headers
   with `erx_net_frame` over its path and the next hop's neighbour row
   ([Framing](#framing)), computing the checksum over the headers and
   payload with `erx_bytes:inet_csum/2`.
3. **Connection to driver.** All frames of the step go to the driver in
   one message against the driver's credit, each frame as its header
   binary and its payload sub-binaries.
4. **Driver to device.** The driver posts each frame with
   `erx_device:post/4` as the segments `[{out, DeviceHeader}, {out,
   Headers}, {out, Payload}]`; the NIF lays them end to end in a pool
   buffer, the one per-byte copy of the transmit path.

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
path(Dst, Opts, snapshot()) -> {ok, path()} | {error, enetunreach | eaddrnotavail}.
    % Dst zoned; Opts: src, via (an interface), ttl or hlim, tos or tclass, flow
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

**Packets and frames.** `tcp/3`, `udp/5` and `ip/4` build IP packets,
each the iodata `[Header, Payload]` that `erx_ip4:output/4` and
`erx_ip6:output/4` return: the header bytes they build, and the payload
binaries as they were given, not copied. Only a datagram that IP
fragments has its payload joined into one binary, which those functions
then cut into fragments. `tcp/3` encodes each segment with
`erx_tcp_wire:encode/3` over the path's pseudo-header sum and
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
| receive, TCP segment | driver to interface (per batch), interface to connection (per batch) | one per delivery | one, `erx_device:complete/2` |
| transmit, TCP segment | connection to driver (per step) | one per `send` call | one, `post/4` |
| receive, UDP datagram | driver to interface, interface to socket | one per datagram | one |
| ARP, neighbour discovery, ICMP echo, SYN | driver to interface; replies interface to driver | none | one each way |

A lane crossing copies the payload into the lane and out of it, by the
domains design ([design-domains.md](design-domains.md#flow-control)); a
delivery that coalesces several segments' payloads into one binary adds
a copy to save messages, a trade on the performance watch list.

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
| `TF_FASTRECOVERY`, `TF_CONGRECOVERY`, `snd_recover` | the loss module's state: `none`, `{fast, Recover}` or `{congestion, Recover}` |
| `t_timers[]` | `send_timer` and `#deadlines{}` |
| `t_rxtshift` | `rxtshift`, kept when the send timer stops |
| `snd_una`, `snd_nxt`, `snd_max`, `snd_wl1`, `snd_wl2`, `iss`, `rcv_nxt`, `rcv_adv`, `last_ack_sent`, `irs` | the same names, unwrapped integers |
| `snd_cwnd`, `snd_ssthresh` | the congestion module's `#ccv{}`, as FreeBSD's `struct cc_var` |

Options negotiated in the handshake (MSS, window scaling, timestamps,
SACK, ECN) are set once, when the connection is synchronized, and never
change afterwards.

### Events and the step

```erlang
-type event() ::
      {segments, [segment()]}                % from the interface, in order
    | {user, erx_tcp_user:request()}         % connect, send, recv, close, ...
    | {expired, Now :: integer()}            % a timer hint
    | {icmp, erx_tcp_icmp:report()}          % unreachable, too big
    | {buffer, Kind :: snd | rcv, Bytes :: non_neg_integer()}.

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

The user requests are FreeBSD's `pr_usrreqs` for a connected stream:
`connect`, `send`, `rcvd` (the owner has read so many bytes, which reopens
the window), `shutdown`, `close` and `abort`. The socket layer above them,
the owner, the active mode, packet framing and the bytes not yet handed to
the owner, belongs to the connection process; the control block counts
those bytes so that the advertised window follows them. A request that
waits carries its caller, and the step answers it from the state it
reaches, after output: `connect` once the connection is established,
`send` once all its bytes are in the send buffer, which takes them as its
free space reaches the low watermark (`sowriteable`), and every
waiting caller with the error when the connection ends. A connection
that `tcp_close` ended (FreeBSD's `INP_DROPPED`, the record's `ended`) is
done, which a new control block in CLOSED is not: the step runs output
only for a connection dropped after it received a SYN, so that output is
the RST of `tcp_drop`, then tells the owner how it ended and returns
`finish`. No stage has to remember any of this, since it follows from the
state.

`tcp_do_segment` is about 2,000 lines that mix state handling, ACK
processing and data delivery. It is split by stage, not ported in order.
A segment's step is a pipeline of named stages, each returning
`{continue, Tcb, Seg}` (with any actions), `{goto, Stage, Tcb, Seg,
Actions}` or `{done, Tcb, Actions}`, in the order
`tcp_do_segment` takes them, since the order is visible on the wire (a
RST, for example, is judged before the timestamp check):

1. `lift` the segment into the connection's sequence space
   (`tcp_input.c:1511-1629`): a SYN-ACK in SYN-SENT that acknowledges
   what was never sent is answered with a RST, `t_rcvtime` is taken,
   the window scaled and the timestamp echo brought back to our clock.
   FreeBSD also reads the segment's ECN here, before any check; the
   stack reads it in `check_ack`, once the segment has passed them all,
   so a blind segment can neither cut the congestion window with ECE
   nor make the connection echo CE or stop echoing it. TIME-WAIT's
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
stages' work from `ack` on: it applies what the checks it skips would
set (the receive window, `ts_recent`, ECN) and jumps to `ack`. FreeBSD's
fast path repeats that work in a shorter form that leaves different
state (`snd_wl1` and `rcv_up` after a pure ACK, `t_dupacks`, the
spurious-timeout rule), and one translation of each effect cannot
drift. It is also where a native fast path would
go, if one is ever measured to be needed
([Where C is used, and what is measured](#where-c-is-used-and-what-is-measured)).
Its decision to skip the checks must not drift from them, so a property
test runs generated segments and states, those header prediction accepts
and their near misses, through the general stages too and requires the
same state and actions wherever header prediction accepts
([The TCP core: exhaustive exploration](#the-tcp-core-exhaustive-exploration)).
A difference it finds is either a translation bug or a branch FreeBSD
really takes differently, which a packet script then pins. If the
property finds none and the measurements of plan.md's network gates show
the stage saves no time, the stage is deleted, since the general path
then produces the same wire behaviour.

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
headers. The stack uses no segmentation offload.

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
`#sent{next, sent_at, transmissions, sacked, lost, rxt}`, `next` being the
sequence number after the range. Because sequence
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

Two properties hold by construction. A SACK block marks only the ranges
it covers whole, so only the sender's own transmissions create range
boundaries and a peer cannot split the log into pieces smaller than what
was sent; a block covering part of a range is conservative, the range
stays unSACKed, and neighbouring SACKed ranges merge, so repeated or
wide blocks cannot grow the log. And the unSACKed ranges marked lost are
a prefix of the unSACKed ranges, since `IsLost` is monotone downwards and
`lose/3` marks ranges only from `snd_una`, so the pipe is a
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
loss module. RACK-TLP, deferred by
the owner's decision, would be a second one, `erx_tcp_loss_rack`,
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
| SACK with RFC 6675 recovery | on (`tcp_do_sack`, `tcp_do_newsack`) | on, written from RFC 2018, RFC 2883 and RFC 6675 |
| lost-retransmission detection | on (`tcp_do_lrd`) | not built: no RFC specifies it and its code is in `tcp_sack.c` |
| PRR, limited transmit, IW10 | on (`tcp_input.c:162-178`) | on |
| ECN | 2: accept when the peer asks, never initiate (`tcp_do_ecn`, `tcp_ecn.c:106`) | 2, so a peer that asks for AccECN gets RFC 3168 ECN, as `tcp_ecn_syncache_add` answers it (`tcp_ecn.c:509-537`); like FreeBSD, a SYN-ACK with ECE alone turns ECN on although our SYN did not ask, where RFC 3168 section 6.1.1 would leave it off (`tcp_ecn_input_syn_sent`, `tcp_ecn.c:120`) |
| missing timestamps on a connection that negotiated them | tolerated (`tcp_tolerate_missing_ts`, `tcp_subr.c:219`) | tolerated |
| FIN-WAIT-2 recycling at 60 s | off (`tcp_fast_finwait2_recycle`, `tcp_timer.c:143`) | off |
| delayed ACK | on (`tcp_delack_enabled`, `tcp_input.c:152`) | on |
| buffer autosizing | on (`tcp_do_autosndbuf`, `tcp_output.c:116`; `tcp_do_autorcvbuf`, `tcp_input.c:217`) | on, within the grant's buffer budget |
| CUBIC | default (`cc/cc.c:83`) | default |
| path MTU discovery; black-hole detection | on; off (`tcp_timer.c:170`) | on; off |
| `nolocaltimewait` | false (`tcp_timewait.c:91`) | false |

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
reachable, delay and probe entries. FreeBSD's `lltable` has a limit,
`llt_maxentries`, that refuses every new entry once reached, but neither
protocol sets it, so its tables are unbounded. An on-link sender that
fills a table from spoofed sender addresses can therefore push out
entries this host is resolving, and in ARP a neighbour in use, a
residual `TODO.md` records. Both tables
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
routing type with segments left zero ignored, a jumbogram refused),
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
bytes as its credit, and drops beyond it, as a UDP socket's receive
buffer does. UDP-Lite and encapsulation are not part of the stack, and
multicast delivery is `erx_mcast`'s ([Scope](#scope)).

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
| `erx_net_credit` | none | credited hand-over | funnel |
| `erx_net_if`, `erx_tcp_conn`, `erx_tcp_listen`, `erx_udp_sock`, `erx_net_grant`, `erx_net_tables`, `erx_dhcp4`, `erx_epmd`, `erx_net_loop` | none | processes | E |

The client side lives in the `erx` application, which every domain runs:
`erx_gen_tcp` and `erx_gen_udp`, the socket backends, and `erx_inet`,
their shared requests (`getifaddrs`, host name, name servers).

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

`erlang/apps/erx_net/NOTICE-freebsd` records the pinned tag and commit,
the SHA-256 of the source archive the translation was read from, and for
every module the FreeBSD files and functions it derives from, as
`kernel/NOTICE-fiasco` records the kernel's translation from Fiasco. The
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

The grant's limits come from the domain's specification within its
principal's policy:

| Limit | Meaning | Default |
| --- | --- | --- |
| `sockets` | sockets open at once, listeners and accepted connections included | 1,024 |
| `buffers` | bytes of send and receive buffer reserved across the grant's sockets | 16 MiB |
| `time_wait` | connections in TIME-WAIT | 4,096 |
| `ports` | local ports the grant may bind explicitly; ports below 1,024 only when listed, as FreeBSD requires privilege for them (`ipport_reservedhigh`, `in_pcb.c:132`) | 1,024 to 65,535 |
| `listen` | whether the grant may listen, and on which of its ports | yes |
| `addresses` | local addresses the grant may bind | all |
| `share` | reductions per period, the facet's share | the policy's |

Configuring interfaces and reading every client's statistics is a second
facet, `netadmin`, granted to administrators.

### Sockets act for one domain

The grant starts the domain's sockets, except connections accepted on
the domain's listeners, which the interface process starts; every socket
links to its grant and traps exits, so the grant's end reaches it as a
message and it ends, a connection with a RST. A
socket's pid is encoded only in frames to the grantee, so the network
domain's runtime exports it to the grantee alone, with `send` only, and
no other domain can message it
([design-domains.md](design-domains.md#exports)). A socket receives
messages from other domains wrapped with their origin
(`erx:origins(true)`) and checks each request as a facet does, through
the admission path generated from the same schema: the request's origin
against the grantee, its operation and arguments against the schema, its
size and the requests in flight. A reply target or a new owner must be a
pid of the grantee's domain.

A connection waiting in a listener's backlog counts toward that
listener's backlog, which is bounded. It becomes one of the grant's
sockets at `accept`, and `accept` answers `{error, emfile}` while the
grant has no socket left, leaving the connection queued, as UNIX's
`accept` does.

**The grant's account.** Every reduction a socket spends, on its
owner's requests and on the packets that arrive for it, is charged to
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
`recbuf` option, and the grant refuses past its `buffers` limit. A
connection the interface process starts reserves its initial buffers as
it starts and, refused, ends with a RST, as FreeBSD answers a completed
handshake it cannot give a socket. The grant holds each socket's
reservation and releases it when the socket exits, by whatever means.

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
default: `inet:gen_tcp_module/2` and `inet:gen_udp_module/2` return
`erx_gen_tcp` and `erx_gen_udp` for it. A socket is
`{'$inet', erx_gen_tcp, Pid}` or `{'$inet', erx_gen_udp, Pid}`, where
`Pid` is the connection, listener or datagram socket, so `gen_tcp`,
`gen_udp` and `inet` reach the backend through the dispatch they already
have. The connection builds the same term for the messages it sends, so
an owner's `receive {tcp, S, Data}` matches as on stock.

Each call is one request to one process: the grant for `connect`,
`listen` and `open`; the socket for the rest.

| Call | Request | To |
| --- | --- | --- |
| `gen_tcp:connect/3,4` | `{tcp_connect, Family, Remote, Port, Opts, Timeout}` | grant |
| `gen_tcp:listen/2` | `{tcp_listen, Family, Local, Port, Opts}` | grant |
| `gen_tcp:accept/1,2` | `{accept, Timeout}` | listener |
| `gen_tcp:send/2` | `{send, Data}`; the reply comes once the data is in the send buffer, later while the buffer is above its high watermark | connection |
| `gen_tcp:recv/2,3` | `{recv, Length, Timeout}` | connection |
| `gen_tcp:shutdown/2` | `{shutdown, How}` | connection |
| `gen_tcp:close/1` | `close` | socket |
| `gen_tcp:controlling_process/2` | as `inet:tcp_controlling_process/2` (`inet.erl:4595`): `active` set false by request, the caller's queued messages for the socket forwarded, `{owner, Pid}`, `active` restored | socket |
| `gen_udp:open/1,2` | `{udp_open, Family, Local, Port, Opts}` | grant |
| `gen_udp:send/2,3,4,5`, `gen_udp:recv/2,3`, `gen_udp:connect/3` | `{send_to, ...}`, `{recv, ...}`, `{connect, ...}` | datagram socket |
| `inet:setopts/2`, `inet:getopts/2` | `{setopts, Opts}`, `{getopts, Names}` | socket |
| `inet:peername/1`, `inet:sockname/1`, `inet:port/1`, `inet:getstat/2` | `peername`, `sockname`, `{getstat, Names}` | socket |
| `inet:getifaddrs/0`, `inet:gethostname/0` | `getifaddrs`, `hostname` | grant |

A socket closes when its owner exits, as a `gen_tcp` socket does: the
socket monitors its owner. The pushed messages are stock's:
`{tcp, S, Data}`, `{tcp_closed, S}`, `{tcp_error, S, Reason}`,
`{tcp_passive, S}`, `{udp, S, Address, Port, Data}`, `{udp_passive, S}`.
Active modes `true`, `false`, `once` and `N` behave as stock. In `true`
mode, as on stock, nothing limits deliveries except the lane to the
owner's domain: when that lane is full, the connection waits, its credit
fills and its segments are dropped, so memory stays bounded and TCP
recovers when the owner drains.

The packet modes (`{packet, 1|2|4}`, `line`, `http`, `http_bin` and the
rest) frame the stream in the connection with `erlang:decode_packet/3`,
where stock frames it in its inet driver, so an owner receives whole
packets. That is ERTS's C parser running on peer data in the network
domain, as stock runs it in every node, which the owner accepted
([Decisions](#decisions), 6): `decode_packet` gets a fuzz target over
every mode the options offer, and its reach is a security residual
([Residuals](#residuals)).

Where stock OTP's result depends on the kernel beneath it, and the oracle
runs stock on Linux, the stack gives FreeBSD's result, and each such case
is a documented difference with a test. IPv6-only sockets by default are
one: Linux's default admits IPv4-mapped addresses, FreeBSD's does not.

### Options

| Options | Where they act |
| --- | --- |
| `nodelay`, `keepalive`, `linger`, `sndbuf`, `recbuf`, `buffer`, `tos`, `tclass`, `priority`, `reuseaddr`, `reuseport`, `ipv6_v6only`, `send_timeout`, `send_timeout_close`, `high_watermark`, `low_watermark`, `{congestion, Name}`, `{loss, Name}`, the `raw` options FreeBSD's `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, `TCP_KEEPCNT` and `TCP_MAXSEG` map to | the socket's state, read by its step |
| `active`, `mode`, `binary`, `list`, `header`, `packet`, `packet_size`, `deliver`, `exit_on_close`, `show_econnreset` | how the socket presents data to its owner |
| `broadcast`, `multicast_*`, `add_membership`, `drop_membership` | `broadcast` acts; the multicast options act through `erx_mcast` ([Scope](#scope)) |
| `fd`, `netns`, `bind_to_device`, other `raw` options | `{error, enotsup}` |

### The `socket` and `net` modules

OTP's `socket` module calls the `prim_socket` NIF, which erXos drops. An
Erlang `prim_socket` takes its place and speaks the same socket protocol
to the network service, so `socket` and its `gen_tcp_socket` backend
work over the same connection, listener and datagram processes as
`gen_tcp` and `gen_udp`; `net`'s interface and host calls are answered
by the grant. `gen_tcp`, `gen_udp`, `ssl`, `ssh` and distribution do not
use `socket`, so it comes after them, by the owner's decision
([Decisions](#decisions), 5), and plan.md schedules it.

### Name resolution

`inet_res`, OTP's DNS resolver in Erlang, runs over `gen_udp` in each
domain. The grant's `resolver` operation returns the name servers and
search list the network domain learnt from its static configuration,
DHCP or router advertisements (RFC 8106), and a domain's `inet_db` loads
them at start and on the grant's change message.

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
| No atom is made from packet data; unknown protocol values stay integers | the codecs; a build check fails on `binary_to_atom`, `list_to_atom` and `binary_to_term` in `erx_net` |
| Sequence-space conversion happens only in `erx_tcp_seq` | a chokepoint check fails on 2^31, 2^32 - 1 or 2^32 written as an integer literal in any base, or a left shift by a literal 31 or 32, in any other TCP module |
| Half-open connections live only in the bounded syncache; overflow is answered statelessly with cookies | `erx_tcp_syncache` |
| A RST resets only at exactly `last_ack_sent`; a SYN in a synchronized state and an out-of-range ACK get rate-limited challenge ACKs | RFC 5961 stages |
| IP identification values reveal nothing: zero on atomic IPv4 datagrams, random otherwise and on IPv6 fragments | `erx_ip4`, `erx_ip6` |
| Random values (identifications, ephemeral ports, flow labels, nonces, delays, limit jitter) come from the owner's `erx_net_rand` generator, keyed from the kernel's entropy generator; no module of `erx_net` calls `rand` or `crypto` | `erx_net_rand`; a build check |
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
kept or dropped, and only a frame that holds room costs a checksum and
more ([Receiving](#receiving)). A flood of frames with valid checksums aimed
at one client's established connection therefore costs the interface
process no more per frame than any flood of minimum-size frames: once
the connection's credit is full, each further frame is decoded, looked
up and dropped, and what the connection takes, at the rate its grant's
share lets it take it, is charged to that grant. The interface's own
cost per frame is spent on the network domain's grant, the same whoever
the frame names. A frame that holds room and fails its checksum returns
its room, so the checksums of such frames are bounded by link capacity
alone, not by credit or the bucket. Whether one interface process keeps up with
minimum-size frames at line rate is what the network gates measure;
where it cannot, the driver's credit fills and the driver drops frames
for every client alike ([Residuals](#residuals)).

### Residuals

Each of these is a known gap, with the reason it stays:

* **One interface process is a ceiling for all clients.** A line-rate
  flood that the interface process cannot decode as fast as it arrives
  makes the driver drop frames for every client, whatever they are. The
  cost per frame dropped for want of room is a header decode and a
  lookup, kept small by [Receiving](#receiving)'s order, but a frame that
  holds room and fails its checksum costs a checksum as well, at the rate
  the link delivers such frames; one interface process per receive
  queue, on devices that hash flows to several queues ([Scope](#scope)),
  divides the work. A bound per client here would need a classifier ahead
  of the interface process, which is what the interface process is.
* **`erlang:decode_packet/3` runs on peer data** in the network domain
  for the packet modes, as stock runs it in every node. A memory-safety
  bug in that C parser that a peer can reach would end the network domain
  and every client's connections, where on stock it ends one node. It has
  a fuzz target over every mode offered; framing in the client's domain
  would need a client-side process per socket in packet modes
  ([Decisions](#decisions), 6).
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

## Concurrency and failure

### Ordering

Segments of one connection pass through one interface process and one
mailbox, in arrival order, and the connection steps through them one at
a time. A connection's replies and deliveries to its owner travel on one
lane in order, so a reply to `{setopts, [{active, false}]}` arrives after
every delivery sent before it, which `controlling_process` relies on.
Two binders of one key are ordered by `ets:insert_new/2`. The interface
and the driver never send to another domain, so no client can stall
packet input.

### What fails and what survives

| Failure | Seen by | What survives | What ends |
| --- | --- | --- | --- |
| a frame that a step cannot handle (a bug: the step raises) | the interface process, which counts and logs the event | the interface's state from before the frame; every connection | the frame |
| the interface process crashes outside a step | its link supervisor; `erx_net_tables`, which deletes the rows that name it | the driver, every connection | the interface's soft state: neighbours, reassembly, half-open handshakes; its published rows, and with its `erx_dhcp4` a DHCP lease, which the restarted client asks for again |
| the driver crashes, or the device breaks its queue | its link supervisor | every connection; their unacknowledged data is retransmitted | the device's queued frames; the interface process restarts after the driver's reset |
| a socket's step raises (a bug) | the socket, which ends itself from its state before the event, then exits with the exception; its grant deletes its entries and logs the exit | everything else | the socket: a connection sends a RST, and its owner receives `{tcp_error, S, econnaborted}` and `{tcp_closed, S}`, or a waiting call gets the error |
| a socket process is killed or crashes outside a step | its grant, which deletes its entries | everything else | the socket, silently: the peer times out or meets a RST later, and the owner's next call gets `{error, closed}` |
| a socket's owner exits | the socket, which monitors it | everything else | the socket: a connection sends FIN, or RST if `linger` is zero |
| the grant ends (revocation, its domain ends) | its sockets, by the link: each connection sends RST and exits | other grants | the domain's sockets and registrations |
| a client domain stops reading | its lane fills | other domains | that domain's connections slow, then drop, as TCP does |
| a socket died and its entries are not yet deleted | nobody: `classify/2` finds the entry and the frame's message goes to a dead pid | everything else | the frames that arrive before its grant deletes the entries, as if dropped; a TCP peer retransmits and meets a RST once the entry is gone |
| the configuration changed during a batch or between output passes | the next batch's view, the next pass's path | everything | nothing: frames classified or framed against the old copy behave as under FreeBSD's epoch, which lets a lookup finish against the table it started on |
| a next hop does not answer resolution | the interface, which holds up to 16 packets for it | everything else | its held packets: dropped after 20 s for ARP, or the oldest returned as an ICMPv6 address-unreachable to the stack's own socket for neighbour discovery ([Framing](#framing)) |
| the interface's MTU drops under a connection | the connection's next output pass, through the context's MTU | the connection | nothing: on IPv4 the next segment under don't-fragment that would not fit lowers `t_maxseg` and is sized again ([Output](#output)); on IPv6 a segment over the MTU is fragmented, as FreeBSD sends it |
| a route goes away under a connection | the connection's next output pass | the connection, which sends nothing until a route returns | the connection, at its retransmission timeout: with `ehostunreach` once it has received a SYN, with `etimedout` in SYN-SENT |
| `erx_net_tables` or a top-level child exceeds its restart intensity | the network domain's supervisor | nothing in the domain | every socket; owners' next calls get `{error, closed}` |

A raising step is caught in two places, and in both the step's purity
makes the handling complete: the exception leaves the state exactly as
it was before the event. The interface process drops the frame, keeps
its state and goes on, since a frame is its unit of work and its state
serves many flows. A socket ends itself properly from its intact state,
as the table says, and then exits with the exception as its reason, since
its state is one flow's and a bug in it is not worth keeping alive. Both
record the exception and the event, a frame's length and its first 128
bytes escaped, in the kernel log, and count it. No other exception is
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
| `{error, enobufs}` | a buffer reservation exceeds the grant's `buffers` limit |
| `{error, eaddrinuse}` | the key is held, under FreeBSD's reuse rules |
| `{error, eaddrnotavail}` | the local address is not the machine's, no usable source address leaves through the route's interface, or no ephemeral port is free |
| `{error, econnrefused}` | a RST answered the SYN |
| `{error, etimedout}` | connection setup or retransmission exceeded FreeBSD's limits |
| `{error, enetunreach}` | `connect`, or a datagram sent without a local address, finds no route (`in_pcbladdr`) |
| `{error, ehostunreach}` | a datagram's route has gone (`ip_output`); a synchronized connection's soft error at its timeout; an unreachable report in SYN-SENT |
| `{error, econnreset}` | a RST in a synchronized state, under `show_econnreset` as on stock |
| `{error, closed}` | the socket is closed, as on stock |
| `{error, timeout}` | an Erlang call's own timeout, as on stock |
| `{error, emsgsize}` | a datagram larger than IP allows, or a packet over `packet_size` |
| `{error, einval}` | an option value out of range |
| `{error, enotsup}` | `fd`, `netns`, `bind_to_device`, unknown `raw` options, SCTP |
| `{error, badarg}` | a request the admission path refuses: wrong origin, schema or size |

## Where C is used, and what is measured

C does per-byte work only, as the design requires
([design.md](design.md#decisions)).

* **The Internet checksum,** `erx_bytes:inet_csum/2`, already among the
  per-byte primitives, over an iolist so headers and payload are summed
  without being joined. It uses the CPU's checksum-friendly instructions
  where the architecture layer has them, with portable C as their oracle.
  Where the device offers checksum offload, as virtio-net does, the
  driver uses it ([Scope](#scope)): it saves this pass but adds
  per-frame flag handling to the driver, and the C checksum stays for
  devices without it and as the offload's oracle.
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
  ([design.md](design.md#decisions)), and the stack calls it
  only when an owner starts and when
  `erx_net_tables` draws or rotates a secret
  ([One owner, one step](#one-owner-one-step)).

Everything else is Erlang. Whether TCP's established path also needs
native code is measured on this stack: a bulk transfer and a
request-response load against line rate at 1 Gb/s (81,274 full-size
frames a second each way, 12.3 us a frame), with the time per frame
broken down by stage: completion, classification, checksum, step,
encoding, posting and the lane crossing. The measurements on erXos's
kernel decide and those on the Raspberry Pi 4 confirm or reopen the
decision; the same measurements on QEMU on the stopgap are a baseline
that decides nothing, since every interrupt and doorbell there passes the
stopgap's one service thread (plan.md's gates GN-QEMU, GK3 and GN-board).
If the established path misses line rate and the breakdown names a pure
function of the core as the cost, that one function gets a NIF with the
same signature, and the Erlang function stays as its oracle in a
differential test over the same inputs. The process structure does not
change.

Costs this design leaves unmeasured are on the performance watch list,
[todo-performance.md](todo-performance.md).

## Verification

Each test below is paired with a seeded failure: a deliberate fault the
test must catch, kept as a fixture, which proves the code under test ran.

### Codecs: fuzz targets

One fuzz target per decoder, in `test/erlang/*_fuzz.erl`, run by `make
check-fuzz`: Ethernet, ARP, IPv4 with options, IPv6 with extension
headers, ICMP, ICMPv6 with neighbour-discovery options, UDP, TCP with
options, DHCP, epmd's requests, the packet-mode framing over random
streams (`decode_packet` over every mode the options offer), and the
socket protocol's requests through the generated validators. Each
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
judge must both refuse.

*Seeded failure:* a decoder variant that trusts the IPv4 total length
without checking it against the frame, and one that accepts a TCP data
offset below 5; each must fail its target's agreement check within the
target's budget.

### Checksums and random values: the interface's gate and the generators

A host test drives the interface process, with a stand-in driver and
stand-in sockets, through three cases: a segment with a correct checksum
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
recovery state) until no new abstract state appears, or to depth 8. The
whole exploration runs again with the initial sequence numbers just
below 2^32, so every position class is also crossed at the wire
boundary. On every transition it checks:

* `snd_una =< snd_nxt =< snd_max`, and `rcv_nxt` never decreases;
* no byte is delivered twice or out of order, and none beyond what the
  peer sent;
* no segment is sent beyond the peer's window, except a window probe of
  one byte, measured from the furthest acknowledgement the peer sent:
  FreeBSD's window update takes the window of an acknowledgement below
  `snd_una` as counting from `snd_una` (`tcp_input.c`'s step 6), where
  RFC 9293 ignores it;
* a RST resets only at exactly `last_ack_sent`; challenge ACKs never
  exceed their limit;
* an old acknowledgement never changes the send window (SND.WL1/WL2);
* every state change is one RFC 9293's state diagram allows;
* where header prediction accepts the segment, the general stages give
  the same state and actions;
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
  PAWS are reached in every state;
* **ECN:** ECE and CWR on segments and the CE mark in the IP header, on
  connections with ECN negotiated and without;
* **urgent data:** URG with the pointer inside the segment, beyond it and
  beyond the window;
* **SACK:** duplicate acknowledgements carrying no block, a block inside
  the flight, a block beyond `snd_max` and a block below `snd_una`
  (D-SACK);
* **the peer's window:** zero, below one MSS and full, so persist,
  window probes and silly-window avoidance are reached, and a SYN with
  window scaling or with FreeBSD's least MSS (`tcp_minmss`, 216 bytes).
  That MSS is larger than the base's buffers, so this dimension's
  connection has a send buffer of two such segments and more, and one
  output pass sends more than one segment (`sendalot`);
* **ICMP reports:** fragmentation-needed or packet-too-big, and
  unreachable, each quoting a sequence number in flight and one outside
  it, in every state.

Their added properties: a report quoting a sequence number outside
`snd_una` to `snd_max` changes nothing; a window probe is sent only while
the peer's window is zero; no segment carries more data than the MSS;
CWR is sent only after the window was reduced, on ECE received or after
a segment was sent again on a timeout or three duplicates
(`cc_cong_signal` owes CWR for `CC_ECN`, `CC_RTO` and `CC_NDUPACK`
alike); and the step's results in the presence of an unnegotiated option
equal its results without it.

*Seeded failures:* the window update without the WL1/WL2 rule; RST
accepted anywhere in the window; RST judged against `rcv_nxt` with an
acknowledgement delayed; `rcv_nxt` advanced without lifting; an ICMP
report acted on without its sequence check; header prediction that skips
the timestamp precondition (PAWS). Each must be caught with a named
property and the shortest trace.

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

* **On FreeBSD.** The oracle guest, a FreeBSD 15.1 QEMU image fetched at
  a pinned hash, runs the scripts with nplab's packetdrill, the version
  the suite names. packetdrill is GPL-2.0, so its source, fetched by the
  pinned fetch step, is built and run only inside the guest as a test
  tool, never linked to or shipped with anything of erXos's. The run
  records which scripts pass on the pinned release; that record is the
  expected verdict per script.
* **On erXos.** `erx_net_script`, erXos's own runner in Erlang, reads the
  scripts' language, with no code of packetdrill's, and drives the stack:
  on the host against the pure core with virtual time, and in hosted mode
  against the whole network domain through a packet-pipe driver, so the
  effect layer and timing run too. A script's socket calls become socket
  requests; its packets are injected at the interface; its expected
  packets are matched against what the driver is given.

Every script's verdict on erXos must equal its verdict on FreeBSD 15.1.
A difference is a bug, a documented departure with a test, or a recorded
FreeBSD bug. erXos's own scripts, run by both runners in the same way,
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
passing everything.

### Traffic against FreeBSD and Linux

Bulk transfers, many short connections and request-response loads run
between an erXos guest and the FreeBSD guest, and between erXos and the
Linux oracle guest, through a host relay that drops, delays and reorders
frames by a seeded schedule. The tests check completion, delivered bytes,
and that retransmission counts and throughput stay within stated bounds
of FreeBSD's own against the same schedule.

*Seeded failure:* SACK disabled on erXos must push its retransmissions
past the bound under a loss schedule where FreeBSD recovers with SACK.

### OTP's suites

`make check-oracle` runs OTP 29.1.2's `gen_tcp_api_SUITE`,
`gen_tcp_misc_SUITE`, `gen_tcp_echo_SUITE`, `gen_udp_SUITE` and
`inet_SUITE` on erXos and on stock on the host and compares them case by
case, and the `socket` suites, and `ssl` and `ssh` over the stack.

*Seeded failure:* a build whose `inet_backend` default is left at `inet`
must fail the suites on erXos, since no inet driver exists, which shows
the suites reach `erx_gen_tcp`; and a backend that drops
`controlling_process`'s forwarding must fail its cases.

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
[Concurrency and failure](#concurrency-and-failure).

*Seeded failures:* the syncache bound removed must exceed the memory
bound under the SYN flood; credits disabled must let a connection's
mailbox exceed its bound under a junk flood to its four-tuple; the
router-list bound removed must grow the interface's memory under the
advertisement flood; the checksum verified before the credit check must
show in the interface's time per dropped frame under the flood to one
connection; and a socket that charges no reductions must let the flooded
client's sockets spend past that bound.

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
* a received segment, datagram or ICMP record is constructed only by its
  `*_wire` decoder; that the decoder checks the checksum before it
  decodes is not something a build check can see, and the decoders' fuzz
  targets with wrong sums and the interface's gate prove it
  ([Codecs: fuzz targets](#codecs-fuzz-targets));
* no module of `erx_net` calls `rand` or `crypto`, and only its process
  modules call `erx_bytes:entropy/1`;
* no `binary_to_atom`, `list_to_atom` or `binary_to_term` in `erx_net`;
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
TCP with the defaults of [Defaults kept](#defaults-kept); the grant, its
limits and its account; `gen_tcp`, `gen_udp` and `inet`; the POSIX socket
protocol; the resolver operation; the port mapper; and every test of
[Verification](#verification).

**Extensions,** each a FreeBSD decision translated by the same rules and
behind the same processes, with no change to the core's structure:

* `socket` and `net` over an Erlang `prim_socket`
  ([The `socket` and `net` modules](#the-socket-and-net-modules));
* raw ICMP and ICMPv6 sockets for `ping`, translating the parts of
  `raw_ip.c` and `raw_ip6.c` that `ping` uses, each a datagram socket of
  the grant that receives the ICMP echo replies its identifier names;
* checksum offload where the device offers it
  ([Where C is used, and what is measured](#where-c-is-used-and-what-is-measured));
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
module, deferred by the owner's decision; BBR as a congestion module,
with pacing in output; DCTCP as a congestion module over the ECN signal;
TCP Fast Open (`tcp_fastopen.c`); and TCP-MD5 signatures (RFC 2385),
whose option `erx_tcp_wire` records so that the syncache refuses a signed
segment as FreeBSD refuses it for a listener without TCP-MD5 (`syncache_add`, `syncache_expand`).
None of them is designed here, and none needs a change outside the seams
it plugs into, except pacing, which BBR brings.

## Decisions

The owner settled these, each as the design recommended.

1. **The grant's account covers its sockets.** Every reduction a grant's
   sockets spend, on requests and on packets, is charged to the grant's
   account, and client requests go straight to the socket processes,
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
6. **Packet modes are framed in the network domain** with ERTS's C
   `decode_packet`, as stock frames them in its inet driver
   ([The backend](#the-backend)). The parser gets a fuzz target over
   every mode offered, and its reach is a security residual
   ([Residuals](#residuals)). Framing in the client's domain instead
   would need a client-side process per socket in packet modes, a hop
   that `gen_tcp`'s other modes do without.
7. **RACK is deferred.** The default stack is the reference, and
   RACK-TLP and BBR come later behind the seams
   ([Why FreeBSD's default stack](#why-freebsds-default-stack)).
   RACK-TLP is a second TCP implementation in FreeBSD, with its own input
   path and the high-precision timer system; the send log keeps it cheap
   to add as a loss module when its value is measured.

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
system sends a byte. The owner deferred it ([Decisions](#decisions), 7);
the send log keeps it cheap to add later as a loss module.

**A process per layer.** Each layer would add a mailbox trip per packet
and serialise all connections through each layer's process; the
interface process decodes all layers in one pass.

**Socket processes in the client domain,** as OTP's `socket` backend
keeps a `gen_statem` per socket in the caller's node. The TCP state
would still live in the network domain, so a client-side process only
adds a hop; and with it, active-mode deliveries could not go straight to
the owner.

**Every request through a facet in the system domain.** The client's
facet would forward each `send` to the network domain and relay each
reply: two more crossings per call, and packet work would still be
unaccounted. The grant runs in the network domain, as the storage
services' grants run in theirs ([design-files.md](design-files.md)).

**Asynchronous sends with a credit window.** `gen_tcp:send` could return
before the connection has the data, against a byte credit the
connection returns, as the inet driver queues sends. It saves a round
trip per call but needs a client-side process to take the returned
credit for every process that may send. Measured first; the synchronous
send is what OTP's `socket` backend does too.

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

**lwIP behind a NIF.** A C stack in the domain that parses hostile
packets, whose numbers would decide nothing about an Erlang stack. The
stack has no stopgap.

## References

* FreeBSD src, `release/15.1.0-p6`, commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`: `sys/netinet`,
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
