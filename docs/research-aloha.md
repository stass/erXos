# Research record: aloha as the starting point for erXos's TCP/IP stack

A point-in-time report of whether the aloha stack could be the base of
erXos's TCP/IP stack, and what an Erlang stack gets wrong when it starts
from the RFC state diagram. [design-network-stack.md](design-network-stack.md)
rests on it. Its findings are not edited in place; a re-check gets a new
record.

Date: 2026-11-07. Host: Apple Silicon macOS. Compiler check: stock OTP
29.1.2's `erlc`, the oracle build of the erXos tree. Nothing else from the
third-party code was executed (no rebar, no build scripts, no tests).

Sources read, from clones at the commits below kept outside the tree:

| Repository | Commit | Date of last commit |
|---|---|---|
| github.com/yamt/aloha | 0aa96f14a326aa8d0fb57743d4a7ea58d22312ed | 2014-09-19 |
| github.com/yamt/aloha_packet | e6f2297b48c9b34fe68ef9d0024be080d32a6372 | 2014-09-19 |
| github.com/javier-paris/erlang-tcpip (A Coruna stack, Apache-2.0) | 708b57fa37176980cddfd8605867426368d33ed1 | 2016-08-17 |
| github.com/javier-paris/etcpip (same stack, GPLv3) | c6a5bdfdb39769db0b053e7aed2b78d39a787756 | 2016-07-22 |

What erXos needed, as the documents read on that date, from `docs/design.md`
(Networking, lines 1463-1527) and
the Phase 1b draft of `docs/plan.md` (1b-G, gate GN-QEMU, M14, gate G14): an Erlang stack
in the network domain covering Ethernet, ARP, IPv6 neighbour discovery, IPv4,
IPv6, ICMP, UDP and TCP; every connection a process; per-packet work by
binary matching in Erlang, per-byte work (checksum, ring-to-binary copy) in C
primitives, with a received frame copied once; decoders with fuzz targets;
per-client caps on sockets and buffers, a bounded ingress budget for unowned
traffic, and survival of invalid traffic and of connection and reassembly
floods; accepted against Linux's stack with packetdrill-style scripts; gate
GN-QEMU measures UDP echo and TCP bulk transfer against 1 Gb/s line rate
(81,274 full-size frames/s, 12.3 us a frame). DHCP and DNS are not named in
the design's stack.

## 1. License

- **aloha** and **aloha_packet**: `LICENSE` in each is the 2-clause BSD
  licence, "Copyright (c)2013 YAMAMOTO Takashi". All 24 `.erl` files in
  `aloha/src` and every `.erl`/`.hrl` in `aloha_packet` carry the same BSD-2
  header. Only `aloha/test/cover.spec` (2 lines, a cover config) has no
  header. No file under another licence; no GPL, Apache or MIT text anywhere.
- **Build dependencies** (not cloned, not in the tree): `lager` (Apache-2.0,
  through a parse transform declared in `aloha/rebar.config` and
  `aloha/test/aloha_test_SUITE.erl:27`) and `eenum` (a parse transform used by
  `aloha_packet/src/aloha_enum.erl:26`). Both are removed by the import
  package (P0 below), so no non-BSD code would enter the tree.
- **erlang-tcpip**: Apache-2.0 (`LICENSE`, per-file headers "erlang-tcpip,
  Copyright (C) 2004 Javier Paris ... Licensed under the Apache License,
  Version 2.0"). `EQC_CI_LICENCE.txt` is a Quviq CI agreement, not a code
  licence. **etcpip** is the same code under GPLv3: do not use it; use the
  Apache-2.0 repository if any of that code is wanted.
- **msantos/pkt**: BSD-3-Clause, last pushed 2022-06-18 (checked through the
  GitHub API, not cloned).

## 2. Size and structure

aloha: 2,985 lines in `aloha/src` (24 modules), 983 lines in aloha_packet.
TCP is most of it: `aloha_tcp_conn.erl` 1,105, `aloha_tcp.erl` 231,
`aloha_tcp_seq.erl` 194, `aloha_neighbor.erl` 175, `aloha_socket.erl` 113,
`aloha_tcp_listener.erl` 107, `aloha_tcp_rtt.erl` 68; every other module is
under 140 lines. `aloha_packet.erl` (636) is one codec module that also
covers LLC, SNAP and spanning-tree BPDUs, which erXos does not need.

**Process architecture.**

- One `aloha_nic` gen_server per interface. It receives raw frames as
  `{packet, Bin}` casts from a backend and runs Ethernet, IP and TCP
  demultiplexing. Each layer hands over to the next by
  `gen_server:cast(self(), ...)` (`aloha_protocol:dispatch/2` ->
  `aloha_nic:next_protocol/2`), so a TCP segment passes through the NIC's own
  mailbox three times.
- One `aloha_tcp_conn` gen_server per connection, created with
  `gen_server:start` (not linked to a supervisor) by the NIC process when a
  SYN arrives for a listening port (`aloha_tcp:new_connection/5`). TIME_WAIT
  is held by the same process, hibernated.
- One `aloha_tcp_listener` per listening socket, holding the accept queue.
- One global, registered `aloha_neighbor` gen_server: the ARP/NDP cache in a
  `dict` plus a public ETS fast-path table, and the queue of packets waiting
  for resolution.
- Global named public ETS tables (`aloha_tables`): NICs, connections by
  4-tuple, listeners, and TCP-MD5 keys.

**API.** `aloha_socket` mirrors `gen_tcp`/`inet`: `listen`, `accept`,
`send`, `recv/2,3`, `close`, `shutdown`, `controlling_process`, `setopts`
(only `active`, `md5sig` and no-op `packet raw`, `binary`, `nodelay`),
`peername`, `sockname`. Active, active-once and passive modes; messages are
`{tcp, Sock, Data}`, `{tcp_closed, Sock}`, `{tcp_error, Sock, Reason}`. A
socket is `{aloha_socket, Pid}`. Its `controlling_process` reproduces
gen_tcp's ordering guarantee with a suppress-and-move-messages protocol
(`aloha_tcp_conn:controlling_process/3`), worth reading.

**NIC interface.** A backend is an `{M, F, A}` that is called with an
encoded frame binary; received frames are cast to the NIC as
`{packet, Bin}`. Two backends exist, both loopbacks (`aloha_nic_loopback`,
`aloha_nic_lossyloopback`, the latter dropping 2%). Transmit runs in the
caller's process: a connection encodes the full frame itself
(`aloha_nic:send_packet/2` -> `aloha_packet:encode_packet/2`) and calls the
backend directly, so transmit has no process hop when the neighbour entry is
cached in ETS. Fitting the erXos packet client means writing one backend
module and one receive loop. That part is easy.

## 3. Quality against erXos's rules

**Parsing.** Decoding is binary matching, and any malformed field raises
`badmatch` (negative option length, a short header, a total length longer
than the frame). No atoms are made from input: `aloha_packet:to_atom/2` maps
through a fixed enum table and leaves unknown values as integers, so the
atom table is safe. The result is a mixed atom-or-integer field type, which
every later match has to allow for. The failure model is broken in practice:

- `aloha_nic:handle_cast({packet, Pkt}, ...)` (`aloha_nic.erl:73`) decodes
  Ethernet with no `try` at all. A runt frame shorter than 14 bytes crashes
  the NIC.
- The other layers sit under `catch error:badmatch` (`aloha_nic.erl:80`),
  but a failed match raises `error:{badmatch, V}`, so the clause never
  matches. Errors of type `function_clause` and `case_clause`, for example
  `[_Ip, _Ether] = Stack` in `aloha_tcp:handle/4` or in `aloha_icmp`/
  `aloha_icmpv6` when a packet has an IPv6 extension header, are not caught
  either.
- The NIC is started with `gen_server:start`, outside any supervisor
  (`aloha_nic_loopback:create/2`). **One malformed frame takes the interface
  down for good.** This is the opposite of the design's "a malformed packet
  crashes the process that decoded it".
- Bounds that are not checked even when parsing succeeds: the IPv4 version
  field, IHL below 5 (it crashes rather than being refused), and the IPv6
  payload length, which is ignored (`aloha_packet decode(ipv6)`), so trailing
  bytes after the datagram become payload. The Ethernet type/length cut-off
  is `>= 16#5dc` rather than the 802.3 values (length up to 1500, type from
  1536).
- The checksum outcome is returned as `good`/`bad` and each handler must
  check it. IP, ICMP and TCP do.

**Functional core.** There is none. `aloha_tcp_conn` interleaves decisions
with effects throughout: `tcp_output/3` encodes and transmits
(`build_and_send_packet/5` -> `aloha_tcp:send_packet/3`), starts and
cancels timers and recurses for burst transmit, all within one decision;
`established/1` sends `Owner ! {aloha_tcp_connected, ...}`;
`process_writers/1` and `process_readers/1` call `gen_server:reply`;
`process_input/3` can call `send_rst/1` in the middle of evaluating a
segment. Timestamps come from `os:timestamp()`, a wall clock, inside the
logic. The pure parts are `aloha_tcp_seq` (`trim/6` and `accept_check/4`,
which have unit tests), `aloha_tcp_rtt` (RFC 6298 arithmetic) and the
codec. Moving to the style guide's pure `step(State, Event) -> {State,
Actions}` shape means rewriting `aloha_tcp_conn` rather than refactoring it.

**Tests.**

- `aloha_packet_test.erl`: 31 eunit encode/decode round trips on golden
  packets.
- eunit for `aloha_tcp_seq`, `aloha_addr` and `aloha_utils`.
- `aloha_test_SUITE.erl`: 7 Common Test cases (self-connect, echo, bulk
  transfer, unlisten, recv timeout, close, eaddrinuse). They run across IPv4
  and IPv6, sync and async, lossless and lossy loopback, and with and
  without MD5, repeated.

There are no malformed-input tests, no fuzzing, no interoperability tests in
the repository (`aloha_demo`, which ran cowboy over it, lives in another
repository), and no tests of the state machine on its own. Because the logic
is wired to `self()`, timers, ETS and gen_server replies, it cannot be
tested without running the processes.

**OTP 29.** With the stock OTP 29.1.2 `erlc -Wall`, 27 of 28 source files
compile. The problems:

- `aloha_enum.erl` fails: "undefined parse transform 'eenum'". It is 95
  lines of enum tables and becomes plain functions.
- `aloha_test_SUITE.erl` fails: "undefined parse transform
  'lager_transform'".
- Warnings: `crypto:rand_uniform/2` is deprecated (still exported in OTP
  29's `crypto.erl`; used in `aloha_tcp:choose_port/0` and the lossy
  loopback); `catch ...` is deprecated (`aloha_neighbor.erl:137`); the
  `behaviour aloha_protocol undefined` warnings come only from compile
  order.
- Runtime breakage: without lager's parse transform, the 103 `lager:info`
  and `lager:debug` calls in `aloha/src` are remote calls to functions that
  do not exist, so every code path fails with `undef` until they become
  `logger` macros. That change is mechanical.
- The module names are unprefixed (`aloha_*` is fine, but `aloha_packet`
  and `aloha_addr` would need erXos names), and the global named ETS tables
  conflict with the network service's per-client admission.

## 4. Protocol completeness

| Feature | aloha | Module |
|---|---|---|
| Ethernet II | present | aloha_ether, aloha_packet |
| VLAN 802.1Q | absent | |
| ARP | partial: answers requests, learns only from replies (unsolicited ones included); one request, no retry; no gratuitous ARP; cache flushed in 10-20 s epochs with no bound inside an epoch; unbounded pending queue | aloha_arp, aloha_neighbor |
| Routing / default gateway | **absent**: the neighbour key is the IP destination itself, so every destination is assumed on-link | aloha_neighbor:req_key/1 |
| IPv4 receive | partial: one address, directed broadcast; no version/TTL checks; options ignored | aloha_ip |
| IPv4 fragmentation and reassembly | absent: fragments are decoded as `bin` and dropped | aloha_packet, aloha_default |
| IPv4 ID / DF | wrong: ID always 0 with DF=0 (record defaults in aloha_packet.hrl) | |
| ICMPv4 | partial: echo reply only, and it replies to broadcast; no errors sent or processed | aloha_icmp |
| IPv6 | partial: fixed header only, no extension-header walk, payload length ignored | aloha_ipv6 |
| IPv6 fragments | codec only (aloha_packet), no reassembly | |
| ICMPv6 | partial: echo; NS/NA | aloha_icmpv6 |
| NDP | partial: NS answered, NA learned; no hop-limit-255 validation, no NUD states, DAD, RS/RA, SLAAC, MLD or redirects | aloha_icmpv6 |
| PMTU discovery | absent (on the README's TODO list) | |
| UDP | **absent** (on the README's TODO list) | |
| TCP handshake | present: active and passive, simultaneous open partly handled | aloha_tcp_conn |
| TCP close / half-close | present: FIN states, shutdown read/write | aloha_tcp_conn |
| TCP reset | present, but no RFC 5961 protections | aloha_tcp, aloha_tcp_conn |
| Retransmission | partial: go-back-N from snd_una on timer | aloha_tcp_conn handle_info |
| RTO (RFC 6298) | partial: SRTT/RTTVAR, min 1 s; **no backoff, no retry limit, no user timeout** | aloha_tcp_rtt |
| Delayed ACK | present: 500 ms, ACK every second segment | aloha_tcp_conn:setup_ack/2 |
| Out-of-order reassembly | **absent**: dropped, not ACKed; the author documents hours-long stalls against Linux in the comment in update_receiver/3 | aloha_tcp_conn |
| Flow control | partial: receiver SWS avoidance, zero-window probe and persist (fixed 3 s); no SND.WL1/WL2 window-update rule; default buffers 3,000 bytes | aloha_tcp_conn |
| Window scaling | absent (window capped at 65,535) | |
| Congestion control | **absent**: no cwnd, no slow start; sends the whole peer window in a burst | aloha_tcp_conn:tcp_output/3 |
| Fast retransmit / NewReno / CUBIC | absent | |
| SACK | absent (option only in the codec) | |
| Timestamps / PAWS | absent (option only in the codec) | |
| Keepalive | absent | |
| TIME_WAIT | present: 2*MSL = 60 s, one hibernated process per connection | aloha_tcp_conn |
| Listen backlog | **absent**: unbounded accept queue, option ignored | aloha_tcp_listener |
| Half-open (SYN) limits, SYN cookies | **absent**: a process per SYN, never expired | aloha_tcp:new_connection/5 |
| ISN | **constant 0** | aloha_tcp_conn:init/1 line 101 |
| Ephemeral ports | random 1000-65000, collisions not checked | aloha_tcp:choose_port/0 |
| TCP-MD5 (RFC 2385) | present (not needed by erXos) | aloha_keydb, aloha_packet |
| DHCP, DNS | absent (not in erXos's stack design either) | |

## 5. Correctness and security risks (concrete)

1. **Interface death on one bad frame.** Covered in section 3:
   `aloha_nic.erl:73` and `:80`, plus the NIC running unsupervised.
2. **ISN is always 0** (`aloha_tcp_conn:init/1`, `ISS = 0`). Blind data and
   RST injection are trivial, and every new incarnation of a 4-tuple starts
   at the same sequence number, so old duplicates are accepted. This breaks
   RFC 6528 and RFC 793's ISN clock.
3. **RST acceptance.** A RST anywhere in the receive window resets the
   connection (`process_input/3` with `accept_check/3`), with no RFC 5961
   challenge ACK. In SYN-SENT, `accept_check(_, 0, undefined, _)` accepts
   any RST without checking that its ACK acknowledges our SYN, so with ISN 0
   any 4-tuple-matching RST kills a connect. A SYN in a synchronized state
   is not answered with a challenge ACK either.
4. **SYN flood is unbounded and permanent.** Every SYN to a listening port
   spawns a connection process synchronously inside the NIC process
   (`aloha_tcp:new_connection/5`, which also makes a `gen_server:call` to
   the listener). A SYN-RECEIVED connection retransmits its SYN-ACK every
   RTO (1 s, no backoff, `handle_info({timeout, ...})`) forever, because
   there is no retry limit and no user timeout. Memory and outgoing packets
   grow without bound. This alone fails gate GN-QEMU's connection-flood
   test.
5. **Sequence wrap bugs.**
   - `update_receiver/3` (line 484) sets `rcv_nxt = Seq + 1` without
     `?SEQ`. A peer ISN of 16#ffffffff gives `rcv_nxt = 2^32`, which never
     equals a decoded sequence number, so all data is treated as out of
     order and dropped: the connection stalls.
   - `tcp_output/3` (line 645) computes `SndUna + SndWnd - SndNxt` in plain
     integers. Once `snd_nxt` has wrapped and `snd_una` has not, the result
     is about 2^32 and is capped only by the MSS, so a segment can be sent
     beyond the peer's window. With ISS 0 this happens after 4 GiB.
   - `aloha_tcp_seq:trim/5` uses `WinStart + 999999` as a stand-in right
     edge (marked `XXX`).
   - The comparison macros in `aloha_tcp_seq.hrl` are correct.
6. **Window update without WL1/WL2** (`process_ack/2`, line 316). Any
   acceptable ACK overwrites `snd_wnd`, so a reordered old ACK can shrink or
   reopen the send window. Duplicate ACKs are recognised only when the
   window is unchanged and are not counted, so there is no fast retransmit.
7. **No congestion control.** `tcp_output/3` loops ("burst transmit") until
   the peer's window or the send buffer is exhausted. This is
   non-compliant with RFC 5681 on any shared path.
8. **Timers.**
   - RTT samples use `os:timestamp()` (`tcp_now/0`), a wall clock that can
     step, giving negative or huge samples.
   - The persist timer is a fixed 3 s.
   - TIME_WAIT reuses `rexmit_timer`.
   - A reader timeout returns a short read where gen_tcp would not (the
     author's own `XXX`).
9. **Listener crash.** `aloha_tcp_listener:handle_call({setopts, ...})`
   returns `{ok, State2}` (line 57), which is not a valid gen_server reply,
   so any `setopts` on a listening socket crashes it.
10. **Passive connections echo the peer's IP header.**
    `aloha_tcp:make_reply_template/1` (lines 67-68) copies the received SYN's
    IP record and swaps the addresses, so replies carry the SYN's TTL as it
    arrived (already decremented, possibly 1), its TOS and its ID.
11. **IPv4 ID 0 with DF 0** on every packet. This violates RFC 6864 and
    makes reassembly ambiguous if a router fragments.
12. **Neighbour cache poisoning.** NA and ARP replies are accepted
    unsolicited, and NA is accepted without the hop limit 255 check RFC 4861
    requires, so an off-link host can spoof NDP. The cache and the pending
    queue have no size bound within a 10 s epoch.
13. **Smurf amplification.** `aloha_ip` accepts directed broadcast and
    `aloha_icmp` answers echo requests sent to it.
14. Small items: the IPv6 payload length is ignored; the Ethernet length/type
    cut-off is wrong; port choice does not check for collisions.

## 6. Performance shape

Receive path per TCP segment:

- driver/backend -> NIC mailbox (cast);
- three self-casts in the NIC (Ethernet -> IP -> TCP);
- an ETS lookup of the 4-tuple;
- a cast to the connection process;
- `{tcp, ...}` to the owner, or a gen_server reply to a passive reader.

That is two process hops plus two extra mailbox round trips in the single
NIC process, which serialises all connections of an interface.

Copies of the payload:

- **Receive**: the TCP checksum builds `<<Phdr/bytes, Data/bytes>>`, a full
  copy of the segment, then sums it 16 bits per recursion in pure Erlang.
  The receive buffer append `<<RcvBuf/bytes, Data/bytes>>` is a second copy,
  unless the append optimisation applies.
- **Transmit**: `aloha_packet:encode/4` builds each layer as
  `<<Hdr, Rest/bytes>>`, so the payload is copied once for the TCP checksum
  input, once for the TCP segment, once for IP and once for Ethernet,
  possibly a fifth time for padding. That is four or more copies per
  segment, plus a pure-Erlang checksum. The send buffer append adds another
  copy.
- **Logging**: the code makes several `lager:info` calls per segment and
  formats `tcp_summary/2` eagerly.
- **Windows**: default buffers of 3,000 bytes and no window scaling cap
  throughput at about 3,000 bytes per RTT by default, and at 64 KiB per RTT
  at most.
- **Retransmission**: go-back-N retransmission and dropped out-of-order
  segments make throughput collapse on any loss.

Against the 12.3 us per frame budget, the pure-Erlang checksum plus four
transmit copies and the NIC mailbox traffic will very likely miss line rate.
The design already moves checksum and ring copy to C primitives and wants
one copy on receive, so aloha's packet path would be replaced in any case,
and measuring aloha's shape would not inform GN-QEMU's decision.

Measurements that would settle each suspicion (host, stock OTP 29 JIT,
nothing on QEMU needed):

- **M1, decode cost**: run `aloha_packet:decode_packet/2` on a 1,514-byte TCP
  frame and on a 60-byte ACK, ns/frame over 10^6 iterations with `timer:tc`,
  with the checksum and without it. Compare with a one-match decoder and a
  C checksum.
- **M2, encode cost**: `encode_packet/2` for a 1,460-byte segment, ns/segment
  and bytes allocated (`erlang:memory(binary)` delta or `msacc`).
- **M3, architecture ceiling**: bulk transfer between two aloha NICs on the
  lossless loopback, logging stubbed out and 64 KiB buffers, MB/s and
  scheduler utilisation; then the same with the self-casts replaced by
  direct calls.
- **M4, NIC serialisation**: N parallel bulk connections; NIC message queue
  length and per-connection throughput as N grows.
- **M5, SYN flood**: process count, memory and outgoing SYN-ACK rate after
  10^5 SYNs. The expected result is unbounded growth.

## 7. Verdict

**Start from scratch, with aloha as a reference. Do not import it as the
base.** Take two pieces deliberately:

- `aloha_tcp_seq` (`trim/6`, `accept_check/4` and their unit tests, with the
  comments comparing NetBSD, Linux and RFC 793 at the window edges): about
  200 lines of BSD-2 code that is pure already and correct apart from the
  `999999` stand-in. Import it with attribution and an `ORIGIN.md`, or
  re-derive it with the tests as a check.
- The interoperability notes in `aloha_tcp_conn` (the zero-window-probe ACK
  variant in `process_ack/2`, the out-of-window FIN and window-edge choices,
  the Linux out-of-order stall, the `controlling_process` ordering protocol),
  as input to the network service's design document.

Reasons:

- What aloha has is the easy 30% of a TCP: the RFC 793 state machine with
  go-back-N, delayed ACK and RTT estimation. Everything that makes TCP
  correct against Linux and safe on a network is absent: ISN, RFC 5961,
  backlog and SYN limits, RTO backoff and timeouts, out-of-order queueing,
  window scaling, timestamps, SACK, congestion control and keepalive. So
  are UDP, fragmentation, routing, PMTU and most of NDP.
- Its structure conflicts with three binding rules: functional core with
  effects at the edge (`aloha_tcp_conn` is effect-interleaved throughout),
  fail-safe parsing in the process that met the input (one bad frame kills
  the NIC), and the per-byte work and single copy of the design
  (pure-Erlang checksum, four copies on transmit, three self-casts on
  receive). Fixing these means rewriting `aloha_tcp_conn`, `aloha_nic`,
  `aloha_neighbor` and the codec. Those modules hold more than 70% of the
  code.
- The improve-aloha path therefore turns into a rewrite one module at a
  time, with the added cost of importing, de-lagering and keeping the
  current shape working in between. Section 7.1 estimates both paths at
  about the same size; importing saves one or two packages at most.

**Codecs.** Do not take aloha_packet as the stack's decoder. It is a
general dissector, returns mixed atom/integer records, copies for the
checksum, and fails by crashing. The hot path wants a narrow decoder per
layer that returns `{ok, ...} | {error, Reason}` and hands off sub-binaries.
`msantos/pkt` (BSD-3, wider IPv6 extension-header coverage, maintained until
2022) suits a different role: a **differential oracle for the decoders' fuzz
targets**, fetched at a pinned hash as a test tool and kept out of the tree.
That fits "agreement with ground truth" and "tools and test oracles stay
out of the tree".

### 7.1 Work lists

Packages of about 50-100 agent tool calls each, each ending in one reviewed
commit.

**Option 1, improve aloha:**

| # | Package | Count |
|---|---|---|
| P0 | Import aloha and aloha_packet as erXos code (`ORIGIN.md`, SHA-256): lager to logger (103 calls), eenum to plain functions, drop MD5, LLC, SNAP and BPDU, rename modules, get the CT suite running on host OTP | 1 |
| P1 | Codec: total decoders returning errors, every length checked, IPv6 payload length, fuzz targets with `pkt` as the differential oracle, malformed corpus | 2 |
| P2 | Checksum and copy: switch to the C per-byte primitive (Erlang reference implementation on the host), iolist encode, one copy on receive | 1 |
| P3 | Packet path: NIC onto erXos's packet client, single-pass demux without self-casts, supervision, routing table with gateway, IP ID/TTL/DF fixes | 1 |
| P4 | TCP core rewrite: pure `step/2` returning actions plus an effect shell, the RFC 793 states, exhaustive host tests (replaces most of `aloha_tcp_conn`) | 2 |
| P5 | TCP security: random ISN (RFC 6528), RFC 5961, listen backlog, half-open limit and SYN cookies, SYN-RECEIVED retry limits, RTO backoff and user timeout, port randomisation | 2 |
| P6 | TCP data path: window scaling, timestamps and PAWS, out-of-order queue (bounded), WL1/WL2 rule, large buffers, persist backoff | 2 |
| P7 | Congestion control NewReno (RFC 5681/6582) with fast retransmit; SACK and SACK-based recovery (RFC 2018/6675) | 2 |
| P8 | Keepalive, TIME_WAIT rules, socket semantics towards the network service's protocol and the oracle's socket cases | 1 |
| P9 | UDP | 1 |
| P10 | IPv4 reassembly with bounded memory, ICMP errors and their delivery to TCP and UDP, PMTU discovery | 2 |
| P11 | IPv6: extension headers, reassembly, full NDP (NUD, DAD, RS/RA, SLAAC, MLD for solicited-node addresses) | 2 |
| P12 | ARP done properly: states, retries, bounded cache and pending queue | 1 |
| P13 | Packetdrill-style harness, scripts run against erXos's stack and Linux's in the oracle guest; network test corpus | 3 |
| P14 | Admission: per-client socket and buffer caps, unowned ingress budget, flood tests, inspector statistics | 2 |

Total: **about 25 packages.** P13 and P14 are needed whichever option is
chosen, and so is the GN-QEMU packet-path prototype with its bench (about 1
more).

**Option 2, from scratch with aloha (and erlang-tcpip, lwIP, FreeBSD) as
references:** the same list without P0. P1 and P3 are written fresh at the
same size. P4 is the same 2 packages, but written to the design instead of
around existing code, reusing `aloha_tcp_seq`. **About 24 packages.**

Neither option changes what dominates the cost: TCP's modern features, IPv6
and NDP, and the conformance harness. Option 2 avoids an intermediate
codebase that matches neither the design nor the rules.

**If the owner still wants to try aloha**, the cheapest useful experiment is
P0 plus measurements M1 to M5: about 1 package. It tells concretely how far
the existing shape is from the GN-QEMU budget before anything else is
committed to it.

## 8. The A Coruna stack

The repository is `github.com/javier-paris/erlang-tcpip`, last commit
2016-08-17, **Apache-2.0**. `github.com/javier-paris/etcpip` is the same
code under GPLv3 and is not usable. The Apache repository is presumably the
release Thomas Arts described at EUC 2017; its only QuickCheck file is
`test/checksum_eqc.erl`, so the QuickCheck TCP model from Arts's 2009 and
2017 work is not in it.

Shape:

- About 4,500 lines of Erlang plus two C programs: `c_src/eth_driver.c`, a
  raw-Ethernet port driver, and `c_src/checksum.c`, a checksum port.
- IPv4 only.
- A reader process and a writer process per layer, all globally registered
  (`eth`, `ip`, `arp`, `icmp`, `eth_port`), and one TCB process per
  connection, with one module per TCP state (`closed.erl`, `syn_sent.erl`,
  ..., `time_wait.erl`).

It has some of what aloha lacks:

- UDP (`udp.erl`);
- IPv4 reassembly (`fragment.erl`, a process per datagram with no timeout,
  per its own TODO);
- slow start and congestion avoidance (`congestion.erl`, floating-point
  cwnd, no fast recovery);
- an out-of-order queue (`out_order.erl`);
- a default gateway (`ip.erl`).

Its weaknesses are as serious:

- The ISN is predictable: `iss.erl` seeds from the clock and adds 64,000
  per connection.
- `seq:sub/2` uses `rem`, which goes negative across the wrap.
- `out_order:get_out_order/2` returns `{none, T}`, discarding the head entry
  when it lies beyond the requested sequence number, and `merge_data/2`
  handles only exact adjacency, not overlap.
- MSS is the only TCP option.
- There is no IPv6, ARP has no timeouts, and the etcpip TODO lists
  unimplemented resets in several states.
- Its process per layer means more hops per packet than aloha, the opposite
  of the design's decode-once shape.

It does not change the verdict: it is a second reference, mainly for its
per-state module layout and the 2005 paper's optimisation notes, and if its
code is consulted it must be the Apache-2.0 repository.

## Sources

- aloha and aloha_packet: https://github.com/yamt/aloha, https://github.com/yamt/aloha_packet (commits above)
- erlang-tcpip: https://github.com/javier-paris/erlang-tcpip; etcpip: https://github.com/javier-paris/etcpip
- Paris, Gulias, Valderruten, "A high performance Erlang Tcp/Ip stack", Erlang Workshop 2005, DOI 10.1145/1088361.1088372; slides https://erlang.org/workshop/2005/tcpip_presentation.pdf
- T. Arts, "Performance and Testing of an Open Source Erlang TCP/IP Stack", EUC 2017: https://www.erlang-factory.com/euc2017/thomas-arts, https://codesync.global/older-conferences/euc_2017/thomas-arts/
- msantos/pkt: https://github.com/msantos/pkt (licence and module list via the GitHub API)
- The compile logs were kept outside the tree and are not preserved.
