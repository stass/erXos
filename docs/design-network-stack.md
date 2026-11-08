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
  serves both FreeBSD's RFC 6675 recovery and a later RACK-TLP.
* **C does only per-byte work:** the Internet checksum and the SipHash
  keyed hash, both per-byte primitives of the runtime. Whether TCP's
  established path needs native code is measured on this stack.

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
16. [Staging](#staging)
17. [Alternatives considered](#alternatives-considered)
18. [Open decisions](#open-decisions)
19. [Changes needed elsewhere](#changes-needed-elsewhere)
20. [References](#references)

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
| RACK and BBR | `tcp_stacks/rack.c` 24,673, `tcp_stacks/bbr.c` 14,824, `tcp_hpts.c` 2,137 | 41,634 |

The default stack is the reference: it is the stack FreeBSD runs and
FreeBSD's TCP test suite checks, its congestion-control seam is small,
and RACK and BBR are each a second TCP implementation that needs the
high-precision timer system and its own input path before it sends a
byte. Most of the default stack's volume is locking, mbuf handling,
sysctls, logging and kernel plumbing; what is translated is its
decisions. Its seams are kept so that RACK-TLP (RFC 8985) can be added
later as a loss-detection module, read from `rack.c` for its logic, and
BBR stays for later, as the owner agreed.

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
* The per-byte primitive `erx_bytes:inet_csum/2` is specified
  ([design-runtime.md](design-runtime.md#per-byte-primitives)) but not
  written: `erlang/apps/erx/src/erx_bytes.erl` exports `crc32c/2` and
  the SHA-256 calls only.
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
  progress while excess is dropped.
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
route and link MTU, the published neighbour entry. The function reads no
clock, no ETS table and no process; it returns the next state and a list
of actions from a closed vocabulary (transmit these frames, deliver these
bytes, reply to this caller, end). The loop reads the context, calls the
step, performs the actions in order and arms its one timer. The step
never sends, so an exception inside it leaves the state exactly as it was
before the event.

Because no state has two writers, there are no locks, no reference counts
and no epochs: a connection's end is its process's exit, and a pid that
names a dead process names nothing ([design-domains.md](design-domains.md#invariants), D1).
Other processes read only what an owner publishes in an ETS table: the
demultiplexing entries, each held by one socket, and the neighbour
entries and routes, each written by its interface.

### Deadlines, not timers

FreeBSD 15 keeps an array of deadlines in each control block and one
callout set at the earliest of them (`tcp_timer_next`, `tcp_timer_enter`
and `tcp_timer_activate`, `tcp_timer.c:854-935`). The stack keeps the same
shape. A connection's state holds its deadlines (retransmission or
persist, keepalive, delayed ACK, 2MSL, and whatever the loss-detection
module asks for); `erx_tcp:next_deadline/1` returns the earliest. After
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
`send_timer :: none | {rexmt, Deadline, Shift} | {persist, Deadline, Shift}`.
The interface process keeps its deadlines (neighbour retries, reassembly
lifetimes, syncache retransmissions, router and prefix lifetimes) the
same way.

### Credited queues

ERTS bounds no mailbox, and a stack under attack is a set of mailboxes
that someone else fills. So no stack process hands packets to another
except through `erx_net_credit`:

* The receiver creates an `atomics` counter and publishes it with its pid:
  the driver in its interface record, a connection or socket in its
  demultiplexing entry, an interface in its interface record.
* A sender adds the units it is about to send (frames, segments or
  bytes, as the receiver chose) with `atomics:add_get/3`. If the result
  exceeds the receiver's limit, it subtracts them again and does not send.
* The receiver subtracts the units of each message it takes.

Every queue between driver, interface and socket is therefore bounded by
construction, and a full queue drops at the sender, which counts the drop
by reason. For TCP the transmit credit is an input of the step: when the
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
unnecessary: for example `TF2_NO_ISS_CHECK`, which turns off the
ghost-ACK check once `snd_una` is far enough past the initial sequence
number that a modular comparison with it means nothing
(`tcp_input.c:2416-2441`), disappears, because the acceptable
acknowledgement's lower bound is simply
`max(iss + 1, snd_una - max_sndwnd)`.

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
| virtual network stacks (`VNET`) | one stack per network domain |
| sysctl registration | the `erx_net` application's environment, and per-socket options |
| syncache buckets, per-bucket locks and callouts | one bounded table per interface process, one deadline |
| the function-block registry and aliasing (`tcp_subr.c:392-740`) | a closed table of loss and congestion modules |
| BlackBox logging, DTrace probes, `tcp_pcap` | every connection is a process the inspector and tracer see |

## Processes and the packet path

### The process tree

```text
erx_net_sup  (rest_for_one)
 |- erx_net_tables          ETS tables, secrets, port-mapper names
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
reassembly queues and half-open handshakes, which peers retransmit.

Connections, listeners and datagram sockets are never restarted, since a
restarted TCP connection would be a different connection: each is a
`proc_lib` process running the `gen_server` loop, linked to its grant,
so the grant's end ends it and its crash is reported to the grant. The
grant traps exits, so a socket's crash ends only that socket.

### Receiving

A TCP segment for an established connection whose owner is in client
domain D:

1. **Device to driver.** The device writes a frame into a pool buffer. The
   driver's interrupt message makes it call `erx_device:complete/2`, which
   copies up to 64 KiB of completed frames into fresh binaries: the one
   per-byte copy of the receive path. The driver strips the device's own
   header (virtio's `virtio_net_hdr`) and sends the batch to the interface
   process in one message, against the interface's credit. The driver
   parses nothing else, as sDDF's split of driver and protocol prescribes
   ([design.md](design.md#drivers-and-dma)).
2. **Interface: decode, check, classify.** For each frame the interface
   process runs `erx_net_input:classify/2`, a pure function of the frame
   and the interface's published view, which decodes Ethernet, IP and
   TCP, verifies the checksum with `erx_bytes:inet_csum/2` (a read pass,
   no copy), and looks up the demultiplexing table. It returns one of
   `{owned, Pid, Credit, Item}` for a segment, datagram or ICMP report that
   belongs to a socket, `{local, Event}` for what the interface itself
   handles (ARP, neighbour discovery, ICMP echo, fragments, segments for a
   listener) and `{drop, Reason}`.
3. **Interface to connection.** The owned items of one batch are grouped
   by destination, and each destination gets one message holding its
   items in arrival order, against its credit. The items are records whose
   payloads are sub-binaries of the frames, so nothing is copied.
4. **Connection.** The connection folds `erx_tcp:step/3` over the
   segments, one at a time, exactly as FreeBSD processes one segment at a
   time, collecting the actions. It then sends all frames the steps
   produced (ACKs, data) to the driver in one message, delivers all
   in-order data in one message to the owner, replies to waiting callers
   and re-arms its timer.
5. **Connection to owner.** In active mode the delivery is
   `{tcp, Socket, Data}` sent to the owner in domain D: a frame on the
   lane from the network domain to D, decoded by D's funnel.

### Transmitting

1. **Owner to connection.** `gen_tcp:send/2` in D sends `{send, Data}` to
   the connection with a reply alias: a frame on the lane, decoded by the
   network domain's funnel into a binary of the network domain.
2. **Connection.** The step appends the binary to the send buffer, a queue
   of binaries, and runs output. Each segment's payload is a sub-binary
   of the buffer. The connection encodes the TCP, IP and link headers into
   one binary with `erx_net_frame`, using the route and the neighbour
   entry it reads from ETS on every output pass, and computes the
   checksum over the headers and payload with `erx_bytes:inet_csum/2`.
3. **Connection to driver.** All frames of the step go to the driver in
   one message against the driver's credit, each frame as its header
   binary and its payload sub-binary.
4. **Driver to device.** The driver posts each frame with
   `erx_device:post/4` as the segments `[{out, DeviceHeader}, {out,
   Headers}, {out, Payload}]`; the NIF lays them end to end in a pool
   buffer, the one per-byte copy of the transmit path.

When the neighbour entry for the next hop is missing or incomplete, the
frame goes to the interface process instead, which holds it while it
resolves the address, at most 16 frames per neighbour as FreeBSD holds
(`arp_maxhold`, `if_ether.c:114`; `nd6_maxqueuelen`, `nd6.c:125`), and
sends it when the neighbour answers. When an entry is stale, the first
transmitter to see it flips the entry's probe flag with
`ets:update_counter/3` and alone sends the interface one hint, so the
interface probes it as FreeBSD's `arpresolve` and `nd6_resolve` do.

### Hops and copies

| Path | Local messages | Lane crossings | Copies in the network domain |
| --- | --- | --- | --- |
| receive, TCP segment | driver to interface (per batch), interface to connection (per batch) | one per delivery | one, `complete/2` |
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
interface process. The loopback interface carries IP packets without a
link header. Everything else about it is the same: the same credits, the
same interface process, the same step functions.

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
| `TF_REQ_TSTMP`, `TF_RCVD_TSTMP`, `ts_recent`, `ts_recent_age`, `ts_offset` | `ts`: `off` or `#ts{recent, recent_age, offset}` |
| `TF_REQ_SCALE`, `TF_RCVD_SCALE`, `snd_scale`, `rcv_scale` | `wscale`: `off` or `{SndShift, RcvShift}` |
| `TF_FASTRECOVERY`, `TF_CONGRECOVERY`, `snd_recover` | the loss module's state: `none`, `{fast, Recover}` or `{congestion, Recover}` |
| `t_timers[]` | `send_timer` and `#deadlines{}` |
| `snd_una`, `snd_nxt`, `snd_max`, `snd_wl1`, `snd_wl2`, `iss`, `rcv_nxt`, `rcv_adv`, `irs` | the same names, unwrapped integers |
| `snd_cwnd`, `snd_ssthresh` | the congestion module's `#ccv{}`, as FreeBSD's `struct cc_var` |

Options negotiated in the handshake (MSS, window scaling, timestamps,
SACK, ECN) are set once, when the connection is synchronized, and never
change afterwards.

### Events and the step

```erlang
-type event() ::
      {segments, [erx_tcp_wire:segment()]}   % from the interface, in order
    | {user, erx_tcp_user:request()}         % connect, send, recv, close, ...
    | {expired, Now :: integer()}            % a timer hint
    | {icmp, erx_tcp_icmp:report()}          % unreachable, too big
    | {buffer, Kind :: snd | rcv, Bytes :: non_neg_integer()}.

-type action() ::
      {transmit, [erx_tcp_wire:outgoing()]}
    | {deliver, iodata()}
    | {notify, closed | {error, atom()} | {ready, [readiness()]}}
    | {reply, gen_server:reply_tag(), term()}
    | {reserve_buffer, snd | rcv, Bytes :: non_neg_integer()}
    | {reinject, erx_tcp_wire:segment()}
    | finish.
```

`erx_tcp:step/3` is the only entry. It dispatches the event to the module
that translates the FreeBSD code for it, then runs output, as
`tcp_do_segment` ends by calling `tcp_output` when an ACK or data is due.

`tcp_do_segment` is about 2,000 lines that mix state handling, ACK
processing and data delivery. It is split by stage, not ported in order.
A segment's step is a pipeline of named stages, each returning
`{continue, Tcb, Seg}` or `{done, Tcb, Actions}`, in the order
`tcp_do_segment` takes them, since the order is visible on the wire (a
RST, for example, is judged before the timestamp check):

1. `lift` the segment into the connection's sequence space.
2. `syn_sent`: the SYN-SENT case of `tcp_do_segment`
   (`tcp_input.c:2017`), which validates a SYN-ACK's acknowledgement,
   handles RST, negotiates options and moves to ESTABLISHED or
   SYN-RECEIVED.
3. `check_rst`: RFC 5961 section 3: a RST whose sequence number is
   exactly `rcv_nxt` resets; one elsewhere in the window gets a challenge
   ACK (`tcp_input.c:2167`).
4. `check_syn`: RFC 5961 section 4: a SYN in a synchronized state gets a
   challenge ACK (`tcp_input.c:2204`).
5. `paws`: RFC 7323's check against the last timestamp
   (`tcp_input.c:2218`).
6. `trim`: trims the segment to the receive window, as the `todrop`
   blocks do (`tcp_input.c:2259`).
7. `check_ack`: RFC 5961 section 5 and the ghost-ACK check
   (`tcp_input.c:2416-2450`).
8. `ack`: SYN-RECEIVED to ESTABLISHED, duplicate-ACK detection, the loss
   module's `ack` callback, `snd_una` advance, the RTT sample, the
   window update under the SND.WL1/SND.WL2 rule, and the transitions when
   our FIN is acknowledged.
9. `urgent`: the urgent pointer, processed as FreeBSD does
   (`tcp_input.c:3104`); the urgent byte is held out of band, and
   `gen_tcp`, like stock, has no way to read it.
10. `data`: in-order data to the receive buffer, with the delayed-ACK
    decision; out-of-order data to the reassembly queue; the receiver's
    SACK blocks, D-SACK included (`tcp_input.c:3165`).
11. `fin`: the FIN transitions to CLOSE-WAIT, CLOSING or TIME-WAIT
    (`tcp_input.c:3319`).

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
`tcp_input.c:1731`), is a stage of its own between `lift` and
`syn_sent`, where FreeBSD has it, with FreeBSD's preconditions (an
established connection, the segment at `rcv_nxt` with only ACK set, the
window unchanged, no retransmission in progress, an empty reassembly
queue, the timestamp no older than the last), so it takes the branch
FreeBSD takes. It is also where a native fast path would
go, if one is ever measured to be needed
([Where C is used, and what is measured](#where-c-is-used-and-what-is-measured)).

### Output

`erx_tcp_output` translates `tcp_default_output` (`tcp_output.c:186`) and
`tcp_setpersist` (`tcp_output.c:1744`): what to send and when, Nagle,
sender and receiver silly-window avoidance, window updates, zero-window
probes, options on each segment (`tcp_addoptions`, `tcp_output.c:1794`),
and, from the loss module, what to retransmit first. It takes the
transmit credit from the context and never emits more frames than the
credit allows. It produces abstract segments; `erx_net_frame` encodes
them with the path's headers. Segmentation offload is not used in the
first version.

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

The time base is `erlang:monotonic_time/1`, read by the process and
passed in the context. The timestamp option's clock is that time in
milliseconds plus a per-connection offset, a keyed hash of the four-tuple
as `tcp_new_ts_offset` computes it (`tcp_subr.c:3443`), on by default in
FreeBSD (`tcp_ts_offset_per_conn`, `tcp_subr.c:224`).

### The send log, SACK and reassembly

The sender's record of what it has sent is one structure,
`erx_tcp_sendlog`: an ordered map from each sent range's first byte to
`#sent{last, sent_at, transmissions, sacked, lost}`. Because sequence
numbers are integers, the map is an ordinary `gb_trees` keyed by them.
RFC 6675's scoreboard is computed from it, holes, `IsLost`, `NextSeg` and
the pipe included, and so is what RACK-TLP needs: each range's last
transmission time is there. FreeBSD keeps two structures for this, the
default stack's hole list (`tcp_sack.c`) and RACK's sent-segment hash, and
never unified them, which is one reason RACK is a second stack. Here the
loss modules read and mark the one log, and output takes the next range
to send from it.

The receiver's side translates `tcp_update_sack_list`
(`tcp_sack.c:289`) and D-SACK. `erx_tcp_reass` translates `tcp_reass`
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
%% recovery, and return the congestion signals it raises.
-callback ack(erx_tcp_loss:ack(), erx_tcp_sendlog:log(), State, Now) ->
    {erx_tcp_sendlog:log(), State, [erx_tcp_cc:signal()]}.
%% The retransmission timer expired.
-callback rto(erx_tcp_sendlog:log(), State, Now) ->
    {erx_tcp_sendlog:log(), State}.
%% How much may be sent now during recovery, and from where.
-callback allowance(State, erx_tcp_cc:ccv()) -> erx_tcp_loss:allowance().
%% The module's own deadline, such as RACK's reordering timer.
-callback deadline(State) -> integer() | infinity.
-callback expired(erx_tcp_sendlog:log(), State, Now) ->
    {erx_tcp_sendlog:log(), State, [erx_tcp_cc:signal()]}.
```

The default module, `erx_tcp_loss_dupack`, translates the default stack:
three duplicate ACKs, RFC 6675 SACK-based recovery, NewReno partial
ACKs when SACK is off (`tcp_newreno_partial_ack`, `tcp_input.c:4114`;
`tcp_sack_partialack`, `tcp_sack.c:971`), proportional rate reduction
(`tcp_do_prr_ack`, `tcp_input.c:4026`; on by default, `tcp_do_prr`,
`tcp_input.c:162`), limited transmit (`tcp_do_rfc3042`, `:172`) and the
lost-retransmission check (`tcp_sack_lost_retransmission`,
`tcp_sack.c:1156`). A later `erx_tcp_loss_rack` implements RFC 8985 over
the same log.

`erx_tcp_cc` is `struct cc_algo` (`cc/cc.h:145-195`): `init/1`,
`conn_init/1`, `ack_received/3` with FreeBSD's `CC_ACK` and `CC_DUPACK`,
`cong_signal/3` with `CC_NDUPACK`, `CC_ECN`, `CC_RTO` and `CC_RTO_ERR`
(`cc/cc.h:119-128`), `post_recovery/1`, `after_idle/1`, `ecn_pkt/2`,
`newround/2` and `rtt_sample/2`, each a pure function of FreeBSD's
`struct cc_var` as `#ccv{}` and the module's own state. The callers
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
computes its initial sequence number with `erx_tcp_isn`, sends the SYN
and acknowledges its start. `erx_tcp_isn` translates `tcp_new_isn`
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
* SYN cookies are on, as FreeBSD's default (`tcp_syncookies`,
  `tcp_syncache.c:105`): every SYN-ACK's initial sequence number is a
  cookie (`tcp_syncache.c:1726-1729`), a SipHash-2-4 MAC of the
  connection under a secret rotated every 15 s (`syncookie_mac`,
  `tcp_syncache.c:2190-2223`; `SYNCOOKIE_LIFETIME`,
  `tcp_syncache.h:110`). When the table is full, a SYN gets a cookie and
  no entry. An ACK that matches no entry is checked as a cookie only if
  the table overflowed in the last 15 s, as FreeBSD checks only after an
  overflow (`tcp_syncache.c:1095-1110`). The cookie secrets are
  stack-wide, in `erx_net_tables`, so an ACK that arrives on another
  interface still validates.
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
The process hibernates for the 2MSL period, 60 s, so it holds only its
smallest heap. It keeps FreeBSD's rules (`tcp_twcheck`,
`tcp_timewait.c:197`): a RST in TIME-WAIT is dropped (RFC 1337), and a
new SYN that RFC 6191 allows, by a newer timestamp or a higher sequence
number, ends the old connection: the process removes its entry and
returns the SYN to its interface process with `{reinject, Segment}`,
which looks for a listener as `tcp_twcheck` returning true makes
`tcp_input` do.

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
(`tcp_input.c:3742`); an unreachable report in SYN-SENT ends the
connection, as `tcp_drop_syn_sent` (`tcp_subr.c:3559`) does.

### Defaults kept

| Feature | FreeBSD default | Stack |
| --- | --- | --- |
| syncache and SYN cookies | on (`tcp_syncache.c:105`) | on |
| RFC 5961 | on (`tcp_insecure_syn`, `tcp_insecure_rst`, `tcp_insecure_ack` all 0, `tcp_input.c:197-209`) | always on; no knob |
| RFC 6528 | `tcp_new_isn` | always |
| window scaling and timestamps | on (`tcp_do_rfc1323`, `tcp_subr.c:207`) | on |
| SACK with RFC 6675 recovery, lost-retransmission detection | on (`tcp_do_sack`, `tcp_do_newsack`, `tcp_sack.c:125-130`; `tcp_do_lrd`, `tcp_sack.c:152`) | on |
| PRR, limited transmit, IW10 | on (`tcp_input.c:162-178`) | on |
| ECN | 2: accept when the peer asks, never initiate (`tcp_do_ecn`, `tcp_ecn.c:106`) | 2, RFC 3168 first; AccECN later |
| delayed ACK | on (`tcp_delack_enabled`, `tcp_input.c:152`) | on |
| buffer autosizing | on (`tcp_do_autosndbuf`, `tcp_output.c:116`; `tcp_do_autorcvbuf`, `tcp_input.c:217`) | on, within the grant's buffer budget |
| CUBIC | default (`cc/cc.c:83`) | default |
| path MTU discovery; black-hole detection | on; off (`tcp_timer.c:170`) | on; off |
| `nolocaltimewait` | false (`tcp_timewait.c:91`) | false |

## IP, neighbours and UDP

### IPv4 and ARP

`erx_ip4` translates the decisions of `ip_input.c` and `ip_output.c`:
version, header length, total length and checksum checks, trailing bytes
cut at the total length, the bogus-address checks, delivery or drop (the
stack forwards nothing), header fields on output, and fragmentation of
datagrams larger than the path MTU. IPv4 options are checked for their
lengths and otherwise skipped, and a packet carrying a source-route
option is dropped, as FreeBSD's defaults drop one that reaches a host
(`ip_dosourceroute` and `ip_acceptsourceroute` both 0,
`ip_options.c:70-80`); skipping the record-route and timestamp options
is a departure visible only in echo replies, which FreeBSD gives the
request's options. `erx_ip4_reass` translates `ip_reass.c`, with
FreeBSD's caps on the datagrams in reassembly, the fragments per datagram
and the lifetime of a queue, all charged to the interface. `erx_icmp4`
translates `ip_icmp.c`: echo replies, but never to a broadcast or
multicast destination, and errors generated within FreeBSD's limit of
200 a second (`icmplim`, `ip_icmp.c:84`). Redirects are ignored, a
departure from FreeBSD's default of accepting them (`drop_redirect`,
`ip_icmp.c:128`; `icmp6_rediraccept`, `icmp6.c:125`): a host behind one
router never receives one, and accepting them belongs to the second
stage.

`erx_arp` translates `if_ether.c`: the entry states, requests retried 5
times (`arp_maxtries`, `if_ether.c:102`), entries kept 20 minutes once
resolved (`arpt_keep`, `if_ether.c:100`), 16 frames held per unresolved
entry, gratuitous ARP and FreeBSD's rules for which replies may create
or update an entry. The table has a bound per interface, and past it the
oldest unresolved entry goes first.

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
packet-too-big.

`erx_nd6` translates `nd6.c` and `nd6_nbr.c`: the neighbour cache's
states with unreachability detection, neighbour solicitations and
advertisements accepted only with a hop limit of 255 (RFC 4861),
duplicate address detection, and 16 frames held per unresolved
neighbour. `erx_nd6_rtr` translates `nd6_rtr.c` and `in6_ifattach.c`:
router solicitations, router advertisements, the default-router and
prefix lists with their lifetimes, and stateless address
autoconfiguration (RFC 4862). The interface joins the all-nodes and
solicited-node groups and sends the MLDv2 reports those groups need, so
switches that snoop MLD forward neighbour solicitations; nothing else of
multicast is in the first version. Redirects are ignored. Interface
identifiers follow [Open decisions](#open-decisions), item 2.

`erx_in6_src` translates `in6_src.c`, RFC 6724's source address
selection. IPv6 sockets are IPv6-only by default, as FreeBSD's
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
forwarding tables. A connection keeps its route and the route table's
generation, and checks the generation on every output pass.

The network domain's configuration names each interface's mode:
`static` with addresses, routes and name servers; `dhcp`, for which the
link supervisor starts `erx_dhcp4`; and whether IPv6 autoconfiguration
runs, which it does by default. `erx_dhcp4` is a pure RFC 2131 state
machine with RFC 2132's options, in a process that sends and receives
through its interface process directly, as FreeBSD's `dhclient` uses
BPF before the interface has an address.

### UDP

`erx_udp` translates `udp_usrreq.c` and `udp6_usrreq.c`: the checksum
rules (a zero checksum allowed over IPv4, refused over IPv6), delivery to
the socket bound most specifically, ICMP errors delivered to a connected
socket, and port unreachable errors within the ICMP limit. A datagram
socket holds received datagrams up to its receive buffer, counted in
bytes as its credit, and drops beyond it, as a UDP socket's receive
buffer does. UDP-Lite, encapsulation and multicast are not in the first
version.

## Modules and provenance

### Modules

The stack is the application `erx_net`, in `erlang/apps/erx_net/`. Pure
modules are marked P; process modules E.

| Module | FreeBSD source (sys/netinet, sys/netinet6, sys/net) | Role | |
| --- | --- | --- | --- |
| `erx_net_eth` | `if_ethersubr.c` (`ether_input` checks) | Ethernet II codec | P |
| `erx_arp_wire`, `erx_arp` | `if_ether.c` | ARP codec; neighbour state machine | P |
| `erx_ip4_wire`, `erx_ip4` | `ip.h`, `ip_input.c`, `ip_output.c`, `ip_options.c`, `ip_id.c` | IPv4 codec; input and output decisions | P |
| `erx_ip4_reass` | `ip_reass.c` | IPv4 reassembly | P |
| `erx_icmp4_wire`, `erx_icmp4` | `ip_icmp.c` | ICMP codec and decisions | P |
| `erx_ip6_wire`, `erx_ip6` | `ip6_input.c`, `ip6_output.c`, `dest6.c`, `route6.c`, `scope6.c`, `ip6_id.c` | IPv6 codec with the extension-header walk; decisions | P |
| `erx_ip6_reass` | `frag6.c` | IPv6 reassembly | P |
| `erx_icmp6_wire`, `erx_icmp6` | `icmp6.c`, the option parsers of `nd6.c` | ICMPv6 and neighbour-discovery codec; decisions | P |
| `erx_nd6`, `erx_nd6_rtr` | `nd6.c`, `nd6_nbr.c`, `nd6_rtr.c`, `in6_ifattach.c` | neighbour cache, DAD; routers, prefixes, autoconfiguration | P |
| `erx_in6_src` | `in6_src.c` | source address selection | P |
| `erx_net_addr` | `in.c`, `in6.c` | address checks | P |
| `erx_net_route` | none | longest-prefix lookup | P |
| `erx_udp_wire`, `erx_udp` | `udp_usrreq.c`, `udp6_usrreq.c` | UDP codec and decisions | P |
| `erx_tcp_wire` | `tcp.h`, `tcp_dooptions` (`tcp_input.c:3501`), `tcp_addoptions` (`tcp_output.c:1794`) | TCP codec and options | P |
| `erx_tcp_seq` | `tcp_seq.h` | lifting and wire conversion | P |
| `erx_tcp` | `tcp_input_with_port` (`tcp_input.c:594`), per connection | the step: dispatch and output | P |
| `erx_tcp_input` | `tcp_do_segment` (`tcp_input.c:1511`) | the segment pipeline | P |
| `erx_tcp_output` | `tcp_output.c` | output | P |
| `erx_tcp_timer` | `tcp_timer.c`, `tcp_timer.h` | expirations | P |
| `erx_tcp_user` | `tcp_usrreq.c`, `tcp_drop` (`tcp_subr.c:2393`), `tcp_close` (`:2532`), `tcp_newtcpcb` (`:2233`) | user requests | P |
| `erx_tcp_rtt` | `tcp_xmit_timer` (`tcp_input.c:3642`) | RFC 6298 estimator | P |
| `erx_tcp_mss` | `tcp_mss` (`tcp_input.c:3899`), `tcp_mss_update`, `tcp_maxseg` (`tcp_subr.c:3780`), `tcp_compute_initwnd` | MSS and initial window | P |
| `erx_tcp_sendlog` | `tcp_sack.c` sender side (`tcp_sack_doack`, `:576`; `tcp_sack_output`, `:1061`) | the send log and RFC 6675 scoreboard | P |
| `erx_tcp_sack` | `tcp_sack.c` receiver side | SACK and D-SACK blocks | P |
| `erx_tcp_reass` | `tcp_reass.c` | out-of-order queue | P |
| `erx_tcp_loss`, `erx_tcp_loss_dupack` | loss parts of `tcp_input.c` and `tcp_sack.c` | behaviour; default loss detection | P |
| `erx_tcp_cc`, `erx_tcp_cc_newreno`, `erx_tcp_cc_cubic` | `cc/cc.h`, `cc/cc.c`, `cc_newreno.c`, `cc_cubic.c`, the `cc_*` callers in `tcp_input.c` | behaviour; NewReno; CUBIC | P |
| `erx_tcp_ecn` | `tcp_ecn.c` | ECN | P |
| `erx_tcp_isn` | `tcp_new_isn`, `tcp_new_ts_offset`, `tcp_keyed_hash` (`tcp_subr.c`) | initial sequence numbers, timestamp offsets | P |
| `erx_tcp_syncache` | `tcp_syncache.c` | half-open table, cookies | P |
| `erx_tcp_icmp` | `tcp_ctlinput_with_port`, `tcp_mtudisc`, `tcp_drop_syn_sent` | ICMP reports for TCP | P |
| `erx_net_bind` | `in_pcb.c` (`in_pcbbind`, `:716`; `in_pcb_lport_dest`, `:756`; `in_pcbbind_avail`, `:912`; `in_pcbbind_setup`, `:1011`), `in6_pcb.c` | port choice, reuse rules, the claim funnel | P and the funnel |
| `erx_net_input` | `ether_input`, `ip_input`, `ip6_input`, the pcb lookup of `tcp_input_with_port` and `udp_input` | classify one frame | P |
| `erx_net_frame` | the header-building parts of `ip_output`, `ip6_output`, `ether_output` | encode a frame | P |
| `erx_net_if_core` | composes the interface's sub-cores | the interface's step | P |
| `erx_dhcp4_core` | none; RFC 2131 | DHCP client state machine | P |
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
file it translates. Its header carries, after erXos's own notice, every
copyright line and the licence text of each such file at the pinned
commit, and its SPDX line names both licences, such as
`SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause`, so the packer
counts it as third-party for `NOTICES`
([design.md](design.md#licences-and-notices)). Its `-moduledoc` names the
FreeBSD files and the pinned commit; each function that translates a
FreeBSD function says so in its `-doc`, with the FreeBSD function's name,
so a reviewer compares the two side by side.

`erlang/apps/erx_net/NOTICE-freebsd` records the pinned tag and commit,
the SHA-256 of the source archive the translation was read from, and for
every module the FreeBSD files and functions it derives from, as
`kernel/NOTICE-fiasco` records the kernel's translation from Fiasco. A
build check fails when a module's header names a FreeBSD file that the
notice file does not list for it, or the reverse.

Two files are never translated. `netinet/in_cksum.c` carries the
four-clause BSD licence with its advertising clause (`in_cksum.c:17`);
the Internet checksum is erXos's own per-byte primitive. RACK's
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

Every reduction a socket spends, on its owner's requests and on the
packets that arrive for it, is charged to its grant's account, an
`atomics` counter of the period the grant keeps. A socket adds the
reductions of each step, read from `process_info(self(), reductions)`
before and after, and before it takes its next message it compares the
account with the grant's share. While the share is spent, the socket
takes no message until the next period begins: its packet credit fills,
its interface drops further segments for it, and the peer's congestion
control slows. So every reduction the network domain spends is charged
to exactly one account: a grant's for work in its sockets, an
interface's for work in the interface process, and the driver's own. This
extends the facet's account to processes the facet starts; it is
[Open decisions](#open-decisions), item 1.

Buffer space is reserved at the grant: a socket asks its grant, with a
local call, before it grows a buffer by autosizing or by a `sndbuf` or
`recbuf` option, and the grant refuses past its `buffers` limit. A
connection the interface process starts reserves its initial buffers as
it starts and, refused, ends with a RST, as FreeBSD answers a completed
handshake it cannot give a socket. The grant holds each socket's
reservation and releases it when the socket exits, by whatever means.

### Ports and the demultiplexing table

The demultiplexing table, in `erx_net_tables`, maps a key to the socket
that receives for it and the socket's credit:

* `{tcp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`: a
  connection;
* `{tcp_listen, Family, LocalAddr | any, LocalPort}`: a listener, with
  its grant and its options for accepted connections;
* `{udp, ...}`: a datagram socket, bound or connected.

Lookup goes from the most specific key to the wildcard, as
`in_pcblookup_hash` does. Every insertion goes through `erx_net_bind`,
with `ets:insert_new/2`, so a key is held by exactly one socket by
construction and a race between two binders is decided by ERTS. A
chokepoint check fails the build on any other insertion into the table.

`erx_net_bind` translates FreeBSD's port rules: ephemeral ports from
10,000 to 65,535, chosen at random (`ipport_firstauto`,
`ipport_lastauto`, `ipport_randomized`, `in_pcb.c:122-136`), with
`in_pcb_lport_dest`'s search for a free four-tuple; `{reuseaddr, true}`
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
domain, as stock runs it in every node; [Open decisions](#open-decisions),
item 6, asks whether to accept that.

Where stock OTP's result depends on the kernel beneath it, and the oracle
runs stock on Linux, the stack gives FreeBSD's result, and each such case
is a documented difference with a test. IPv6-only sockets by default are
one: Linux's default admits IPv4-mapped addresses, FreeBSD's does not.

### Options

| Options | Where they act |
| --- | --- |
| `nodelay`, `keepalive`, `linger`, `sndbuf`, `recbuf`, `buffer`, `tos`, `tclass`, `priority`, `reuseaddr`, `reuseport`, `ipv6_v6only`, `send_timeout`, `send_timeout_close`, `high_watermark`, `low_watermark`, `{congestion, Name}`, `{loss, Name}`, the `raw` options FreeBSD's `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, `TCP_KEEPCNT` and `TCP_MAXSEG` map to | the socket's state, read by its step |
| `active`, `mode`, `binary`, `list`, `header`, `packet`, `packet_size`, `deliver`, `exit_on_close`, `show_econnreset` | how the socket presents data to its owner |
| `broadcast`, `multicast_*`, `add_membership`, `drop_membership` | `broadcast` acts; the multicast options answer `{error, enotsup}` until multicast is in the stack |
| `fd`, `netns`, `bind_to_device`, other `raw` options | `{error, enotsup}` |

### The `socket` and `net` modules

OTP's `socket` module calls the `prim_socket` NIF, which erXos drops. In
the second stage an Erlang `prim_socket` speaks the same socket protocol
to the network service, so `socket` and its `gen_tcp_socket` backend
work over the same connections. Until then `socket:open` returns
`{error, enotsup}`, a documented difference with a test. `net`'s
interface and host calls are answered by the grant in the same stage.

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
machine's host name ([design.md](design.md#networking)). Which carrier,
plain or TLS, a release build allows is [Open decisions](#open-decisions),
item 4.

## The interface towards POSIX programs

A program's socket descriptor is an open held by its session's handler
([design-programs.md](design-programs.md#descriptors-and-files)), and
the handler is the socket's owner at the network service. The protocol
offers the handler what POSIX needs:

* `{watch, Events}`: the socket sends one `{ready, S, Events}` when it is
  readable, writable, acceptable or has an error, which the handler turns
  into the program's `{ready, Open, Events}`;
* `{recv_nb, Max}` and `{send_nb, Data}`: they never wait, and answer
  `{error, eagain}` when POSIX's nonblocking call would; a program's
  blocking read is a watch followed by a nonblocking read, so no request
  waits in the network domain;
* `accept_nb`, `getsockopt` and `setsockopt` in FreeBSD's names, mapped to
  the same options.

A socket belongs to its grant's domain, not to one program, and lives
until its owner closes it or exits. Programs of one session share a
socket as the handler's open table shares any open: a spawn, a `fork`,
`SCM_RIGHTS` between programs of the session, and an `exec` change only
the handler's holders of the open, and the network service sees nothing
of them. The handler closes the socket when its last holder closes it.
Moving a socket to another domain is not offered.

## Untrusted input

Every packet is hostile. The rules, and where each is enforced:

| Rule | Where |
| --- | --- |
| Every length read from a header is checked against the enclosing layer before use; trailing bytes are cut at the length the header states | each `*_wire` decoder; fuzz targets |
| Decoders are total: `{ok, ...}` or `{error, Reason}`, never an exception | fuzz targets fail on any exception |
| No atom is made from packet data; unknown protocol values stay integers | the codecs; a build check fails on `binary_to_atom`, `list_to_atom` and `binary_to_term` in `erx_net` |
| Sequence-space conversion happens only in `erx_tcp_seq` | a chokepoint check fails on `16#ffffffff` or `bsl 32` arithmetic in any other TCP module |
| Half-open connections live only in the bounded syncache; overflow is answered statelessly with cookies | `erx_tcp_syncache` |
| A RST resets only at exactly `rcv_nxt`; a SYN in a synchronized state and an out-of-range ACK get rate-limited challenge ACKs | RFC 5961 stages |
| Initial sequence numbers are unpredictable (RFC 6528); timestamp clocks are offset per connection | `erx_tcp_isn` |
| ICMP reports act only when their quoted sequence number is in flight | `erx_tcp_icmp` (RFC 5927) |
| Reassembly queues, both IP and TCP, have caps on count, bytes and lifetime; held payloads count at the size they keep alive | reassembly modules |
| Neighbour messages are accepted only by RFC 4861's rules (hop limit 255) and FreeBSD's ARP rules; tables and held packets have bounds | `erx_arp`, `erx_nd6` |
| ICMP errors, RSTs to closed ports and echo replies are rate-limited; no reply to a broadcast or multicast | the interface's limiters |
| Traffic that names no socket spends the interface's budget | the ingress limiter, below |
| Packets queued for any process are bounded | credits |
| Text from packets reaches logs and the inspector only through the sink's escaping function | `erx_log` |

**The ingress limiter.** Owned traffic, a frame that demultiplexes to a
socket, is bounded by that socket's credit and charged to its grant.
Unowned traffic, everything the interface process itself must answer or
hold (SYNs, ARP and neighbour requests, echo requests, fragments, RSTs to
send), spends a token bucket of the interface, in frames per second with
a burst. Past it, unowned frames are dropped and counted while owned
frames and the replies the interface awaits (ARP and neighbour
advertisements for entries it is resolving) still pass. Established
connections and address resolution therefore keep making progress under a
flood of new-connection traffic. The bucket's rate and burst are settled
by gate GN's flood tests.

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
| the interface process crashes outside a step | its link supervisor | the driver, every connection | the interface's soft state: neighbours, reassembly, half-open handshakes |
| the driver crashes, or the device breaks its queue | its link supervisor | every connection; their unacknowledged data is retransmitted | the device's queued frames; the interface process restarts after the driver's reset |
| a socket's step raises (a bug) | the socket, which ends itself from its state before the event, then exits with the exception; its grant deletes its entries and logs the exit | everything else | the socket: a connection sends a RST, and its owner receives `{tcp_error, S, econnaborted}` and `{tcp_closed, S}`, or a waiting call gets the error |
| a socket process is killed or crashes outside a step | its grant, which deletes its entries | everything else | the socket, silently: the peer times out or meets a RST later, and the owner's next call gets `{error, closed}` |
| a socket's owner exits | the socket, which monitors it | everything else | the socket: a connection sends FIN, or RST if `linger` is zero |
| the grant ends (revocation, its domain ends) | its sockets, by the link: each connection sends RST and exits | other grants | the domain's sockets and registrations |
| a client domain stops reading | its lane fills | other domains | that domain's connections slow, then drop, as TCP does |
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
| `{error, eaddrnotavail}` | the local address is not the machine's, or no ephemeral port is free |
| `{error, econnrefused}` | a RST answered the SYN |
| `{error, etimedout}` | connection setup or retransmission exceeded FreeBSD's limits |
| `{error, ehostunreach}`, `{error, enetunreach}` | no route, or an unreachable report in SYN-SENT |
| `{error, econnreset}` | a RST in a synchronized state, under `show_econnreset` as on stock |
| `{error, closed}` | the socket is closed, as on stock |
| `{error, timeout}` | an Erlang call's own timeout, as on stock |
| `{error, emsgsize}` | a datagram larger than IP allows, or a packet over `packet_size` |
| `{error, einval}` | an option value out of range |
| `{error, enotsup}` | `fd`, `netns`, `bind_to_device`, unknown `raw` options, multicast, SCTP, and `socket` until the second stage |
| `{error, badarg}` | a request the admission path refuses: wrong origin, schema or size |

## Where C is used, and what is measured

C does per-byte work only, as the design requires
([design.md](design.md#decisions)).

* **The Internet checksum,** `erx_bytes:inet_csum/2`, already among the
  per-byte primitives, over an iolist so headers and payload are summed
  without being joined. It uses the CPU's checksum-friendly instructions
  where the architecture layer has them, with portable C as their oracle.
  Checksum offload, which virtio-net offers, comes in the second stage:
  it saves this pass but adds per-frame flag handling to the driver.
* **SipHash-2-4,** a primitive this design adds,
  `erx_bytes:siphash24/2`, taking a 16-byte key and an iolist, for
  initial sequence numbers, timestamp offsets and SYN cookies, the hash
  FreeBSD uses for all three. A hash is per-byte work by the design's own
  list, and a SYN flood makes this one per-packet: in Erlang its 64-bit
  arithmetic would leave small integers on every round. It also keeps
  OpenSSL out of the domain that parses hostile packets.

Everything else is Erlang. Whether TCP's established path also needs
native code is measured on this stack, not on any stopgap: a bulk
transfer and a request-response load on QEMU under HVF and natively on
the Raspberry Pi 4, against line rate at 1 Gb/s (81,274 full-size frames
a second each way, 12.3 us a frame), with the time per frame broken down
by stage: completion, classification, checksum, step, encoding, posting
and the lane crossing. If the established path misses line rate and the
breakdown names a pure function of the core as the cost, that one
function gets a NIF with the same signature, and the Erlang function
stays as its oracle in a differential test over the same inputs. The
process structure does not change.

Costs this design leaves unmeasured are listed in
[Changes needed elsewhere](#changes-needed-elsewhere) for the
performance watch list.

## Verification

Each test below is paired with a seeded failure: a deliberate fault the
test must catch, kept as a fixture, which proves the code under test ran.

### Codecs: fuzz targets

One fuzz target per decoder, in `test/erlang/*_fuzz.erl`, run by `make
check-fuzz`: Ethernet, ARP, IPv4 with options, IPv6 with extension
headers, ICMP, ICMPv6 with neighbour-discovery options, UDP, TCP with
options, DHCP, epmd's requests, `erx_net_input:classify/2` over whole
frames, the packet-mode framing over random streams, and the socket
protocol's requests through the generated validators. Each target checks
that the decoder never raises; that encode then decode returns the
record; that it accepts or refuses as a reference judge does, a short
function written from the RFC's validity rules alone; and that on frames
both accept, its fields agree with those of an independent decoder,
`pkt` (github.com/msantos/pkt, BSD-3-Clause), fetched at a pinned commit
as a test oracle and kept out of the tree. Generators bias lengths to the
edges: empty, one short, exact, one long.

*Seeded failure:* a decoder variant that trusts the IPv4 total length
without checking it against the frame, and one that accepts a TCP data
offset below 5; each must fail its target's agreement check within the
target's budget.

### Reassembly and buffers: properties against a byte map

`erx_ip4_reass`, `erx_ip6_reass`, `erx_tcp_reass` and the receive buffer
are checked against a model that records every byte position as a map:
over random sequences of overlapping, duplicate and out-of-range pieces,
the delivered bytes equal the model's, RFC 5722's discard happens exactly
when the model sees an overlap, and the held bytes never exceed the caps.

*Seeded failure:* a reassembly that accepts overlapping IPv6 fragments;
the property must find the overlap.

### The TCP core: exhaustive exploration

`erx_tcp_explore` drives a connection with a small window and MSS, and
a model of its peer, over an abstract alphabet: segments with every
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
  one byte;
* a RST resets only at exactly `rcv_nxt`; challenge ACKs never exceed
  their limit;
* an old acknowledgement never changes the send window (SND.WL1/WL2);
* every state change is one RFC 9293's state diagram allows;
* the step never raises.

*Seeded failures:* the window update without the WL1/WL2 rule; RST
accepted anywhere in the window; `rcv_nxt` advanced without lifting.
Each must be caught with a named property and the shortest trace.

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
FreeBSD bug. Scripts at the 2^31 sequence distance pin the departure that
lifting makes.

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
case, and in the second stage the `socket` suites, then `ssl` and `ssh`
over the stack.

*Seeded failure:* a build whose `inet_backend` default is left at `inet`
must fail the suites on erXos, since no inet driver exists, which shows
the suites reach `erx_gen_tcp`; and a backend that drops
`controlling_process`'s forwarding must fail its cases.

### Floods and failure

On QEMU, against the targets of gate GN: SYN floods, minimum-size frame
floods, fragment floods, connection floods and invalid frames at line
rate, while an established connection and neighbour resolution keep
running. The tests check bounded memory in the network domain, the
established connection's progress, and drop counters by reason. Failure
tests kill the driver, an interface process, a connection, a grant and
the whole network domain under load, and check the survivors of
[Concurrency and failure](#concurrency-and-failure).

*Seeded failures:* the syncache bound removed must exceed the memory
bound under the SYN flood; credits disabled must let a connection's
mailbox exceed its bound under a junk flood to its four-tuple.

### Build checks

Each with a test proving it catches a violation:

* only `erx_tcp_seq` does sequence-space wrap arithmetic;
* only `erx_net_bind` inserts into the demultiplexing table;
* only `erx_net_credit` sends packet batches between stack processes;
* no `binary_to_atom`, `list_to_atom` or `binary_to_term` in `erx_net`;
* every module whose header carries a FreeBSD notice is listed with the
  same files in `NOTICE-freebsd`, and the reverse.

## Staging

**First version.** Ethernet II; ARP; IPv4 with reassembly, fragmentation
on output and ICMP; IPv6 with extension headers, reassembly, ICMPv6,
neighbour discovery, duplicate address detection, autoconfiguration and
the narrow MLDv2 listener; static configuration and DHCPv4; loopback;
UDP; TCP with the defaults of the table above: syncache and cookies,
RFC 5961, RFC 6528, SACK with RFC 6675 recovery and PRR, limited
transmit, IW10, window scaling, timestamps and PAWS, ECN in FreeBSD's
default mode, path MTU discovery, keepalive and persist, buffer
autosizing, TIME-WAIT with RFC 1337 and RFC 6191, reassembly caps,
NewReno and CUBIC; the grant, its limits and its account; `gen_tcp`,
`gen_udp` and `inet`; the POSIX socket protocol; the resolver operation;
the port mapper; every fuzz target, the explorer, both script runners and
the FreeBSD guest.

**Second stage.** The `socket` and `net` modules over an Erlang
`prim_socket`; raw ICMP sockets for `ping`; checksum offload; one
interface process per receive queue where the device has several; the
host cache (`tcp_hostcache.c`); AccECN; ICMP and ICMPv6 redirects
accepted as FreeBSD accepts them; 802.1Q VLANs; RFC 8981 temporary
addresses; multicast with IGMP and full MLD.

**Later.** RACK-TLP as `erx_tcp_loss_rack`; pacing; TCP Fast Open
(`tcp_fastopen.c`); BBR, as the owner decided; DCTCP.

The packet-path prototype that gate GN measures is the first version's
codecs, credits, interface process and the established-connection part of
the TCP core, so the prototype is not thrown away.

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
system sends a byte. The send log keeps RACK cheap to add later.

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

## Open decisions

1. **The grant's account covers its sockets.** The design charges every
   reduction a grant's sockets spend, on requests and packets, to the
   grant's account, and lets client requests go straight to the socket
   processes, which run the facet's generated admission path. This
   extends the facet mechanism, whose account covers the facet's own work
   and the work of the requests it forwards. The alternative routes every
   socket request through the grant, two more local hops per call, and
   leaves packet-driven work unaccounted. *Recommendation:* extend the
   account, as designed.
2. **Interface identifiers.** FreeBSD's default derives SLAAC addresses
   from the MAC address (EUI-64); RFC 7217's stable, opaque identifiers
   are in FreeBSD 15 but off by default (`ip6_use_stableaddr`,
   `nd6_rtr.c:97`; `in6_get_stableifid`, `in6_ifattach.c:342`).
   RFC 8064 recommends RFC 7217, and a MAC address in every IPv6 address
   lets anyone track the machine. RFC 7217 needs a secret that stays the
   same across boots. *Recommendation:* RFC 7217 by default, a departure
   from FreeBSD's default, with the secret provided by the system domain
   from the machine's persistent configuration when it starts the network
   domain.
3. **DHCPv4 in the first version.** QEMU's user network and most home
   networks hand out IPv4 addresses by DHCP, so a Raspberry Pi on a LAN
   needs it. *Recommendation:* include `erx_dhcp4`, written from RFC 2131
   with FreeBSD's `dhclient` as the behavioural reference.
4. **Distribution to other machines in release builds.** OTP's plain TCP
   carrier authenticates by an MD5 challenge over a shared cookie and
   sends everything unencrypted; its TLS carrier authenticates by
   certificates and encrypts. *Recommendation:* release builds allow
   only the TLS carrier, with keys held by the vault through a key facet;
   development builds allow both.
5. **The `socket` module in the second stage.** Until then `socket`
   answers `enotsup`, a documented difference, and OTP's socket suites are
   expected failures. *Recommendation:* accept; `gen_tcp`, `gen_udp`,
   `ssl`, `ssh` and distribution do not use it.
6. **Packet modes framed in the network domain.** `erlang:decode_packet/3`
   is ERTS's C parser; a memory-safety bug in it that a peer can reach
   would end the network domain and every client's connections, where on
   stock it ends one node. Framing in the client domain would need a
   client-side process per socket in packet modes. *Recommendation:* frame
   in the network domain as stock does, with a fuzz target over the modes
   offered, and record the reach of that parser as a security residual.

## Changes needed elsewhere

For the coordinator to apply; this document edits nothing else.

1. **design.md, Document map:** a row for this document: "erXos's TCP/IP
   stack: FreeBSD 15.1's default stack translated into Erlang, the
   process structure and packet path, grants and sockets, verification
   against FreeBSD and stock OTP".
2. **design.md, Networking:** link this document; replace "The stack's
   oracle is Linux's ..." with FreeBSD 15.1 as the reference oracle
   (FreeBSD's TCP test suite run against a FreeBSD guest and against
   erXos, traffic tests against both) and Linux's stack as an
   interoperability peer; per-client admission is the grant in the
   network domain and its account; the ingress budget is the interface's
   token bucket and credits.
3. **design.md, Decisions:** the row "The network stack is erXos's own,
   in Erlang, with lwIP as its stopgap" becomes "The network stack is
   erXos's own, in Erlang, translated from FreeBSD 15.1's default stack",
   with the owner's words as rationale; and the loss and congestion seams
   from day one, BBR later, per the owner's agreement.
4. **design.md, Dependencies:** rows for the FreeBSD source at
   `95719d8a` (translation reference, BSD-2-Clause and BSD-3-Clause,
   permanent, fetched by hash for review, code translated into
   `erlang/apps/erx_net` with notices per module and in
   `NOTICE-freebsd`); FreeBSD's tcp-testsuite (test data, BSD-3-Clause,
   fetched); nplab packetdrill (GPL-2.0, test tool built and run only in
   the FreeBSD guest); the FreeBSD 15.1 QEMU image (oracle guest);
   `msantos/pkt` (BSD-3-Clause, fuzz oracle, fetched).
5. **design.md, Licences and notices:** a sentence parallel to Fiasco's:
   code translated from FreeBSD keeps its notices per module and in
   `erlang/apps/erx_net/NOTICE-freebsd`, and is never translated from
   `in_cksum.c` (BSD-4-Clause) or the unlicensed `tailq_hash.*`.
6. **design-runtime.md, Per-byte primitives:** a row for
   `erx_bytes:siphash24/2` (SipHash-2-4, 16-byte key, iolist; used by
   the network stack; reference: the SipHash paper's test vectors and an
   Erlang model).
7. **design-runtime.md, Erlang-visible behaviour:** the `gen_tcp`,
   `gen_udp`, `socket`, `net` row: `gen_tcp`, `gen_udp` and `inet` reach
   the network service through the `erx` socket backend, `erx_gen_tcp`
   and `erx_gen_udp`, the default `inet_backend`; `socket` and `net`
   answer `enotsup` until the second stage; the `inet_db` row: DNS
   lookups through `inet_res` with name servers from the grant's
   `resolver` operation. The OTP edit adding `erx` to `inet_backend`
   joins the list of edits outside `sys/erxos`.
8. **design-domains.md, Facets, and design-scheduler.md, Service work:**
   if open decision 1 is accepted, processes a facet starts to act for
   its grantee alone (a network grant's sockets) run its generated
   admission path and charge its account, pausing while it is spent.
9. **design-programs.md, Descriptors and files and Compatibility:** a
   socket belongs to the session's domain and its handler is the owner,
   so a spawn, `fork`, `exec` and `SCM_RIGHTS` within a session keep
   socket descriptors as they keep other opens; the documented
   differences for those cases go, and only moving a socket to another
   domain stays unsupported. The `{watch}` row names the socket protocol
   of this document.
10. **design-system.md:** the network domain's configuration (interfaces,
    `static` or `dhcp`, IPv6 autoconfiguration, name servers); the `net`
    grant's limits in the principal policy, and the `netadmin` facet;
    after the network domain restarts, the domain service introduces it
    again to every domain whose specification names a `net` grant, so
    the grants are made anew; the stable-address secret if open decision
    2 is accepted.
11. **plan.md, M12 and M14:** the packet-path prototype is built from
    this document's modules; M14's scope is [Staging](#staging)'s first
    version; its harness is the two script runners and the FreeBSD
    guest; its exit criteria compare against FreeBSD 15.1's verdicts and
    stock OTP's suites rather than against lwIP; gate G14 measures this
    stack against line rate and against FreeBSD's or Linux's stack on the
    same board.
12. **TODO.md:** the network item ("replace lwIP ...") becomes the
    implementation of this design; the item on sockets across spawn,
    fork, `exec` and `SCM_RIGHTS` narrows to moving a socket between
    domains; the `prim_inet` item closes when `erx_gen_tcp` answers
    `eacces` without a grant.
13. **todo-performance.md:** watch items for a round trip per
    `gen_tcp:send/2` across a lane (settle with bulk throughput at 1 KiB
    and 64 KiB sends); coalescing in-order payloads into one binary per
    delivery against one message per segment; the ETS lookups of the
    neighbour entry and route generation on every output pass; one
    interface process per interface as a ceiling on packet rate; the
    memory of a hibernated TIME-WAIT process against FreeBSD's control
    block; the cost of credits and of per-step reduction accounting.
14. **Research records:** the FreeBSD mapping pass and the aloha
    assessment this design rests on become `docs/research-*.md` records,
    with the corrections listed in the hand-off report, so the design's
    evidence is in the tree.
15. **abi/services/net.txt:** the network service's operation schema,
    written with the first code.

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
  RFC 3810, RFC 6724, RFC 7217, RFC 8064, RFC 8106, RFC 8201; RFC 768;
  RFC 2131 and RFC 2132.
* J.-P. Aumasson and D. J. Bernstein, "SipHash: a fast short-input PRF",
  INDOCRYPT 2012.
* aloha, https://github.com/yamt/aloha, commit `0aa96f14`.
* pkt, https://github.com/msantos/pkt.
* Erlang/OTP 29.1.2: `lib/kernel/src/gen_tcp.erl`, `inet.erl`,
  `gen_tcp_socket.erl`, `erl_epmd.erl`.
