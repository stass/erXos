# The fast path of erXos's TCP/IP stack

`erx_net`, the stack of
[design-network-stack.md](design-network-stack.md), decides every TCP
segment in Erlang, in one pure step per segment over the connection's
control block. This document is the stack's performance design: how one
connection carries bulk data at close to the rate of lwIP, a C stack,
over the same medium, and how a small segment, the unit of request-reply
traffic, costs within two to three times what lwIP spends on it. It
extends three parts of the stack's design and takes them as given:
[Checksums in the copy](design-network-stack.md#checksums-in-the-copy),
[The netmap transport](design-network-stack.md#the-netmap-transport) and
[The socket process](design-network-stack.md#the-socket-process).

Decisions every reader needs:

* **A run is the unit of TCP work.** A run is one TCP header, a
  contiguous range of payload and the segment size it is cut at. Output
  emits runs and input takes them, and a segment is a run of one.
  Everything above the medium's copy pays once per run, whatever the run
  holds.
* **The copy into the medium cuts runs.** The copy that the medium forces
  anyway, from binaries into a device buffer, a netmap slot or the
  kernel, also cuts a run into frames. It fills each frame's header from
  the connection's template and finishes each checksum as it copies.
  Cutting is invisible on the wire: the frames are byte for byte the ones
  per-segment output sends.
* **The interface merges before it classifies.** One C call over each
  batch of received frames groups consecutive, in-order segments of one
  flow, by the rule of FreeBSD's large receive offload (LRO,
  `tcp_lro.c`). The interface then classifies and hands on one segment
  for the group, with the number of segments it holds. The merge reads
  only binaries the copy made, so the device NIF still parses nothing a
  device wrote, and the merged payload stays the frames' own sub-binaries.
* **Every TCP decision stays in Erlang.** C copies, sums, writes the
  header values Erlang chose, and groups frames by a fixed rule. What to
  send, when, and what a received segment means are the pure core's
  decisions.
* **The step is lean.** A small control block that stages rewrite,
  header prediction that finishes its two cases in one function, headers
  from a template instead of encoded, a send log of runs, and one step for
  everything waiting in a connection's mailbox. Together they cut a
  single segment's Erlang work to about a quarter.
* **Payload is copied only where something outside the stack forces
  it.** No Erlang code of the stack joins or copies payload except at the
  sites a build check lists. A run's payload stays the binaries the owner
  sent, and a merged segment's stays the frames' sub-binaries, until the
  medium's copy, a lane's copy or the API's binary makes them contiguous.

## Contents

1. [The problem](#the-problem)
2. [The current implementation](#the-current-implementation)
3. [The construction: runs](#the-construction-runs)
4. [Sending](#sending)
5. [Receiving](#receiving)
6. [The lean step](#the-lean-step)
7. [Processes and batching](#processes-and-batching)
8. [Copies](#copies)
9. [The seam](#the-seam)
10. [What the stack believes](#what-the-stack-believes)
11. [Concurrency and failure](#concurrency-and-failure)
12. [Refusals and error results](#refusals-and-error-results)
13. [Verification](#verification)
14. [Open decisions](#open-decisions)
15. [Alternatives considered](#alternatives-considered)
16. [References](#references)

## The problem

### What was measured

On the FreeBSD test host, p620, on 2026-11-09: FreeBSD 16.0-CURRENT
(GENERIC-NODEBUG), AMD Ryzen Threadripper PRO 5995WX with 128 hardware
threads, native. Stock OTP 29.1.1 (erts 17.1, FreeBSD's port, with the
JIT) at default flags, so 128 schedulers. `erx_net` at f3c91786 with the
per-byte primitives' C loaded as a NIF. Frames went over `/dev/tap1`
through the pipe transport's tap helper, then `bridge0` and an `epair`
into a jail running FreeBSD's own stack. Each transfer moved 512 MiB in
64 KiB sends, received with passive `recv(S, 0)`; figures are the median
of three. The raw data, scripts and profiles are in the history
repository at `~/erxos-history/net-perf-p620-2026-11-09/` (commit
`c4f9bf5`). lwIP's measurements are at
`~/erxos-history/net-bench-p620-lwip-2026-11-09/` (commit `8b22014`):
lwIP 2.2.1 with contrib 2.1.0's `tapif`, one thread, the raw API, `-O2`,
a 64 KiB window, over the same tap.

| | `erx_net` | lwIP |
| --- | --- | --- |
| send | 890 Mbit/s | 6,537 Mbit/s |
| receive | 1,143 Mbit/s | 6,809 Mbit/s |
| cost of a 1,448-byte segment | 12.3 us sending and 10.1 us receiving, of the connection process's wall time | 1.5 to 1.6 us of CPU for the whole path, system calls included |
| CPU for 512 MiB | the BEAM's 23.4 s sending (17.9 user, 5.5 system) in 6.2 s, 3.8 cores, with the tap helper's beside it | 0.55 to 0.6 s |
| copies of a payload byte | 4 sending (1 in ERTS, 3 in the kernel); 5 receiving (2 and 3) | 2 each way (1 in user space, 1 in the kernel) |

What the profiles and the experiments established:

* **The connection process is the serial stage, and its cost is per
  segment, not per byte.** A busy wait of 3 us per segment added in the
  connection raised its time per segment from 12.3 to 15.4 us and cut
  sending to 711 Mbit/s, and one of 6 us to 18.1 us and 604 Mbit/s,
  where one serial stage predicts 715 and 598. The same 3 us added per
  frame in the driver cost 3 percent. Caching the encoded TCP options
  gave 14 percent sending and 6 percent receiving. A 256 KiB send buffer
  changed nothing.
* **The cost has no hot spot.** Per segment the connection makes about
  330 Erlang calls and allocates about 1,400 heap words, spread over
  output, acknowledgement input, header and option encoding, the send
  log and the process loop; no function holds more than 4 percent. Each
  stage of the acknowledgement input rebuilds the 78-field control
  block, about ten times per acknowledgement, and output's `commit`,
  `after_send` and `done` copy it again for every segment. Every
  segment's header and options are encoded afresh, and every segment
  adds a node to the send log's `gb_trees`. Minor collections follow the
  allocation, 0.4 to 0.5 per segment.
* **Nothing is batched.** Every hop carries one frame per message, even
  while the connection's mailbox holds 13 items on average.
* **Three processes are spread over 128 schedulers.** The driver, the
  interface and the connection pass each segment from core to core: 113
  of 128 schedulers are more than 1 percent busy, about 15 voluntary
  context switches happen per segment, the scheduler loop and its
  spinning take 11 to 24 percent of all samples, and kernel lock
  spinning under `munmap` takes 8 to 10 percent. The BEAM alone spends
  about four cores for one core of Erlang work in the connection. It
  costs efficiency more than throughput: four schedulers gave 5 to 7
  percent more, one scheduler 10 to 15 percent less.
* **Copies do not limit one flow yet.** The kernel's copy functions are
  about 3 percent of samples, and the hops and copies run beside the
  connection, not in series with it. The driver is close behind the
  connection, so they bind once the connection is about 1.5 times
  faster.

### The two targets

1. **Bulk.** One connection's send and its receive, each at least two
   thirds of lwIP's over the same medium: 4.4 Gbit/s each way over p620's
   tap. At lwIP's rate a segment has about 1.8 us of wall time, which
   every serial stage of the stack must meet once its cost is divided by
   the segments it handles at once.
2. **Small segments.** Request-reply over one connection, with requests
   and replies of 64 bytes to 1 KiB, at a transaction rate of at least a
   third of lwIP's over the same medium, and CPU per transaction at most
   three times lwIP's.

### Why the cost is architectural

Removing every measured share from the per-segment step (option
encoding, the send log's tree, the stages' copies of the control block,
the loop's overhead, the checksum calls and the collections they cause)
brings the step down perhaps twofold, not the sixfold the gap needs; in
the owner's words, "14%+10% won't solve 10x gap". C stacks pay those
costs once per batch or never. FreeBSD's TCP hands a capable interface
one large segment that the hardware cuts (TCP segmentation offload, TSO,
`tcp_output.c:514-565`) and takes merged segments from LRO; lwIP updates
its control block in place. The stack's step per segment is the shape of
the cost, so this design changes the unit of work: a step takes and emits
many segments at once, and the work left for a single segment is cut on
its own.

## The current implementation

Sending: `gen_tcp:send/2` appends a binary to the connection's send
buffer, a queue of binaries (`erx_tcp_sndbuf`). `erx_tcp_output` decides
one segment per pass of its `again` loop and commits it, copying the
control block in `commit/6`, `after_send/3` and `done/2`.
`erx_net_frame:tcp/3` encodes the TCP header and its options
(`erx_tcp_wire:encode/3`, `add_options/1`) and the IP and link headers,
summing the segment with the checksum NIF, three calls and two
`erlang:iolist_to_iovec/1` per segment. The send log inserts one range per
segment. The step's frames go to the driver in one `{transmit, Frames}`
message, and the driver hands each frame to its transport. The tap
transport's `port_command/2` makes ERTS flatten the frame into a buffer,
since the spawn driver has no `outputv` (`io.c` near line 1979;
`sys_drivers.c`'s `spawn_driver_entry`), and the helper writes it to the
tap: a pipe write, a pipe read and the tap's write, three copies in the
kernel.

Receiving: the helper reads a frame from the tap and writes it to its
port; ERTS reads it into a 64 KiB buffer and copies it into a fresh
binary (`driver_output`), one message to the driver. The driver sends it
to the interface, one frame per message. The interface classifies it,
checks its checksums with three NIF calls, decodes it and sends it to
the connection, one item per message. The connection runs it through the
fourteen stages of `erx_tcp_input`, `lift` to `fin`; header prediction
recognises its two common cases and jumps to the `ack` stage, from which
the general stages run. Output then answers about every second segment
with an ACK, encoded as any segment is, and a `recv` joins the queued
payloads into one binary (`erx_tcp_conn:take/2`).

## The construction: runs

### A run

A run stands for one or more consecutive segments of one connection that
differ only where segments must differ:

* the sequence number, which advances by the segment size from frame to
  frame;
* the IP length, the IPv4 header checksum and the TCP checksum, which
  follow from each frame's length and bytes;
* the flags PSH and FIN, which only the last frame may carry.

Every other byte of every frame's headers is the same: the link header;
the IP addresses, type of service or traffic class, flow label, hop limit
and don't-fragment bit; the ports, the acknowledgement number, the window
and the options. A run's options are the timestamps option in FreeBSD's
layout, `NOP NOP TS` (`tcp_addoptions`, `tcp_output.c:1794`), or none,
and the timestamp values are the same for every frame because an output
pass reads the clock once. Every frame but the last carries exactly the
segment size of payload. The last carries the rest, at least one byte,
or nothing when the run is a pure ACK or a bare FIN.

```erlang
%% erx_net_frame: a run, as output hands it to a driver
-record(run, {link :: binary(),          % the link header, from the neighbour row; <<>> without one
              template :: binary(),      % the IP and TCP headers, from the connection's template
              seq :: 0..16#ffffffff,     % the first frame's sequence number, as on the wire
              ack :: 0..16#ffffffff,
              flags :: 0..16#fff,        % the last frame's; the others carry them without PSH and FIN
              win :: 0..16#ffff,
              ts :: none | {TsVal :: 0..16#ffffffff, TsEcr :: 0..16#ffffffff},
              seg :: pos_integer(),      % the payload bytes of each frame but the last
              payload :: [binary()]}).   % at most 64 binaries, sub-binaries of the send buffer
```

A run with its headers is at most `IP_MAXPACKET`, 65,535 bytes, as one IP
packet is, the bound FreeBSD puts on a TSO segment (`tcp_output.c:916-937`,
`t_tsomax`). Its payload is at most 64 binaries, the bound the C that
walks it checks. `erx_tcp_sndbuf:range/4` takes that bound as its fourth
argument and gives a range as at most that many binaries, shorter when the
binaries end first, and output ends a run where the range ends, so no
correct caller passes more. An IPv4 run always carries don't-fragment,
which output sets on every IPv4 segment while the MSS is above
`tcp_minmss` (`dont_fragment/1`, after `tcp_output.c:1494-1498`), and so
its identification is zero by RFC 6864, as `erx_ip4:output/4` sets it
(`ip_fillid`). No frame of a run needs an identification of its own,
and the cut never writes one. IPv6 has none.

On the way in, a run is a merged segment: one TCP segment whose payload
is the payloads of the frames it merged, in order, with the number of
frames ([The merge](#the-merge)).

A segment, in both directions, is a run of one. That is the point of the
construction: the TCP core, the frame layer and the drivers handle one
shape, and the cost above the copy is paid once per run.

### The cut, in the copy

The copy into the medium cuts a run into frames. The cut is a C core in
`erx_net`'s `c_src/`, `erx_tcp_cut.c`, linked by the device NIF, the
netmap NIF and the tap NIF as they link the checksum core of
[Checksums in the copy](design-network-stack.md#checksums-in-the-copy):

```c
/*
 * Checks a run and plans its frames: for frame i, the payload's offset and length, the IP
 * length, the sequence number and the flags. Writes nothing and returns ERX_EINVAL when the
 * template is not one the stack makes, the segment size is zero, the payload has more than
 * 64 pieces, or the run with its headers exceeds IP_MAXPACKET.
 */
int	erx_tcp_cut_plan(const erx_tcp_run_t *run, erx_tcp_cut_plan_t *plan);

/*
 * Writes frame i of a plan to dst, which has room bytes: the link header, the template with
 * the plan's values stored, the payload slice copied through erx_inet_copy_sum, the IPv4
 * header checksum and the TCP checksum. Returns the frame's length, which the plan bounds.
 */
size_t	erx_tcp_cut_frame(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t room);

/*
 * As erx_tcp_cut_frame, for a medium whose copy is the kernel's: writes only the headers to
 * dst and sums the payload slice where it lies (erx_inet_sum), so the caller hands the kernel
 * the headers and the slice.
 */
size_t	erx_tcp_cut_header(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t room);
```

The plan is complete and checked before any byte moves
([style.md](style.md#functional-core)). The template is the stack's own
output, built by `erx_net_frame` from the connection's state, and the
core checks it anyway, since C must never act on a malformed one: IPv4
with a 20-byte header, protocol 6, don't-fragment, offset 0 and
identification 0, or IPv6 with next header 6; a TCP data offset of 5, or
of 8 with `01 01 08 0A` at its first option byte; and nothing after the
TCP header.

Frame i of a run of k frames carries the payload bytes from `i * seg` to
`min(P, (i + 1) * seg)`, where P is the payload's length, and the
sequence number `seq + i * seg` modulo 2^32. The cut stores the IPv4
total length and header checksum (one pair for the full frames and one
for the last) or the IPv6 payload length; the sequence number, the
acknowledgement, the data offset and flags, the window and a zero urgent
pointer; TSval and TSecr when the option is there; and the TCP checksum.
The checksum is the complement of the pseudo-header's sum with the
frame's own TCP length, which the core computes from the template's
addresses, plus the sum of the header and the slice as they are copied.
Every frame but the last carries the run's flags without PSH and FIN.

### The merge, before classification

The interface merges each batch it takes from its driver before it
classifies anything, with one call of a per-byte primitive:

```erlang
-spec erx_bytes:tcp_merge(Frames) -> Units
    when Frames :: [binary() | {sum, Sum, binary()}],      % one driver batch: at most 256 frames, 64 KiB
         Units :: [{sum, Sum, binary()}                     % a frame on its own, with its network sum
                 | {merged, NSegs :: 2..256,
                    First :: {sum, Sum, binary()},          % the unit's first frame, as it arrived
                    Last :: {sum, Sum, binary()},           % its last
                    Payload :: [binary()]}],                % each frame's payload, a sub-binary, in order
         Sum :: 0..16#ffff.
```

Its core, `erx_tcp_merge.c` in `c_src/`, is a pure state machine over the
frames' bytes: given a frame's bytes and the open units, it decides what
happens to the frame. The primitive is one call over the whole batch: on
erXos linked into ERTS as the other per-byte primitives are, and outside
erXos a NIF of the portable build. The rule is FreeBSD's
(`tcp_lro_rx_common`, `tcp_lro.c:1280-1426`; `tcp_lro_condense`,
`:963-1106`); [The merge](#the-merge) gives it in full.

The merge writes no header. FreeBSD rewrites the merged packet's first
header with the last segment's acknowledgement, window and timestamps
(`tcp_lro_update_checksum`, `tcp_lro.c:678`, the stores at `:731-740`);
here the interface reads those from the last frame with its own decoder.
So C decides only which frames belong together, and every value TCP acts
on is decoded by Erlang.

### What follows from it

* **Send offload** is the cut: output emits runs, and the copy each
  medium needs cuts them ([Sending](#sending)).
* **Receive coalescing** is the merge: the interface classifies, credits,
  decodes and hands on one segment per unit, and the connection steps it
  once ([Receiving](#receiving)).
* **The lean path** is what is left: a run of one pays the step alone,
  so the step is made cheap for its common cases
  ([The lean step](#the-lean-step)).
* **Batching** follows from the unit: each hop carries runs and units,
  and each process steps everything waiting for it
  ([Processes and batching](#processes-and-batching)).
* **Copies** do not grow: the cut is the medium's copy, the merge copies
  nothing, and the frame joins that transports make go
  ([Copies](#copies)).
* **The seam** is one capability, who finishes a frame, and one merge
  for every transport ([The seam](#the-seam)).
* **Trust** splits cleanly: the cut reads only the stack's own template,
  and the merge reads only immutable binaries
  ([What the stack believes](#what-the-stack-believes)).

## Sending

### Output makes runs

`erx_tcp_output`'s `again` loop keeps its shape: `decide/3` chooses what
to send, by the rules of `tcp_default_output` up to `send:`. When it has
chosen data, the pass asks whether the segment can be a run of more than
one frame, which holds when all of these do:

1. the connection is synchronized and the segment carries neither SYN nor
   RST (`tcp_output.c:558-565` excludes a SYN);
2. its bytes follow `snd_nxt`; a range the send log chose to send again is
   sent one segment at a time, as FreeBSD's default `tcp_sack_tso` of 0
   sends a SACK retransmission without TSO (`tcp_sack.c:157`,
   `tcp_output.c:561`);
3. the pass's options are a run's: no SACK or D-SACK block to report,
   since "with TSO the TCP header is the same (except for the sequence
   number) for all generated packets" (`tcp_output.c:517-522`), and the
   stack's per-segment output would report D-SACK on one segment only;
4. no urgent data lies ahead (`snd_up` at or below `snd_nxt`), and the
   segment is not a probe (`force_data`) or a persist transmission;
5. ECN output for the segment leaves the connection's ECN state as it
   was and adds neither CWR nor ECE (`erx_tcp_ecn:output/2`), so every
   frame would carry the same codepoint and flags;
6. for IPv4, don't-fragment is set, so the identification is zero;
7. the windows allow at least two full segments: the length `decide/3`
   computes before `transmit/3` clamps it to one segment, `Len`, is at
   least `2 * seg`, where `seg` is `t_maxseg` less the options' length.

The run then takes the largest whole number of full segments that `Len`,
the transmit credit the context offers, the 65,535-byte bound and the
send buffer's 64-binary bound allow; when those bounds leave one
segment, the pass sends it as a run of one, as FreeBSD gives up TSO when
its fragment bound leaves one segment (`tcp_output.c:955-962`). What is
left of `Len` is not part of the run: the next pass of `again` decides
it as a segment, with Nagle and sender silly-window avoidance, from the
state after the run, exactly as the per-segment loop decides its segment
after n full ones. FreeBSD's TSO trims a burst to whole segments in the
same way unless the burst empties the send buffer
(`tcp_output.c:940-948`); here the partial last segment is always a pass
of its own, which gives the per-segment wire.

* **PSH** goes on the frame that carries the send buffer's last byte
  (`push/2`; FreeBSD sets it when the segment sends everything,
  `tcp_output.c:1117-1123`). In a run that is only ever the last frame.
* **FIN** goes on the frame per-segment output would put it on: the last
  frame of a run that ends the data, when a FIN is owed. FreeBSD sends a
  FIN after a TSO burst in a segment of its own (`tcp_output.c:965-969`),
  since it does not trust a device to clear FIN on all but the last
  frame. The stack's own cut clears it, so a run keeps the per-segment
  wire, where the FIN rides on the last data segment.
* **The window.** `Len` already holds the peer's window edge and the
  congestion window's room over the pipe. A window that allows less than
  two full segments makes no run. One that allows two and a half makes a
  run of two and leaves the half for the next pass.
* **The credit.** A run of n frames takes n units of the driver's
  transmit credit, and output never makes a run longer than the credit
  the context offers, as it never emits more segments than the credit
  allows. A credit that runs out mid-pass is `ENOBUFS`, as for any segment
  ([Credited queues](design-network-stack.md#credited-queues)).
* **The path's MTU.** Every full frame of a run has the same size, so
  `transmit/3`'s check against the context's MTU under don't-fragment is
  made once, for a full frame.
* **Bursts.** A run leaves as a burst of up to 45 frames at a 1,500-byte
  MTU, as a TSO segment does. The stack paces nothing, as FreeBSD's
  default stack paces nothing.

After a run, `after_send/3` and `sent/4` run once, as for one segment of
the run's length: `snd_nxt` and `snd_max` move to its end, an RTT probe
starts at its first byte when none runs, the send log records it, the
retransmission timer starts when none runs, and the owed ACK and the
delayed ACK are settled. These are what k per-segment passes leave, since
each of these values is either set once or moved to the end; a property
test checks it ([Verification](#verification)).

A segment that is not a run of several frames is a run of one whenever
its header is a run's (conditions 1 and 3 to 6), retransmissions
included, so no steady segment is encoded in Erlang. The others, a SYN or
SYN-ACK with its options, a RST, a segment reporting SACK blocks, a
segment with urgent data, a probe and an IPv4 segment without
don't-fragment, are encoded by `erx_tcp_wire` as per-segment output
encodes every segment, with the delayed checksum of the checksum
design.

### The header template

The connection keeps the template its runs share in its state: the IP
and TCP headers, encoded once by `erx_net_frame:template/2` from the path
and the connection's negotiated options. It is built again only when the
configuration generation moves, the path changes, or the connection's
MSS or options change, all of which the loop notices. The link
header comes from the next hop's neighbour row at each output pass, as
`erx_net_tx:send/2` reads the row, and the row keeps it encoded. A run
carries the template by reference and its seven values as integers, so
the frame layer writes no header bytes per run.

For a transport that cuts nothing, `erx_net_frame:cut/1` turns a run into
the frames per-segment encoding gives: each frame is
`erx_tcp_wire:encode/4` of the frame's header with its payload slice,
with the sender's checksum. This is the Erlang reference of the cut, and
the differential tests compare the C with it.

### The send log keeps runs

`erx_tcp_sendlog:sent/5` records a run as one range with its segment
size, `#sent{next, seg, sent_at, transmissions, sacked, lost, rxt}`. A
range's segment boundaries are its start plus multiples of `seg`; its
last segment may be shorter. Two rules keep the two properties the
stack's design states for the log ([The send log, SACK and
reassembly](design-network-stack.md#the-send-log-sack-and-reassembly)):

* **SACK marks whole segments.** A SACK block marks the whole segments of
  each range it reaches, splitting the range at segment boundaries, and
  leaves a segment it covers in part unmarked. So boundaries are still
  only those the sender made, the segments it cut rather than the
  transmissions it sent, and a peer cannot split the log below them.
  An acknowledgement inside a segment cuts its range there and at that
  segment's end, so every range starts on a boundary.
* **New data extends the last range.** `sent/5` at `snd_max` extends the
  highest range instead of adding one when that range is unmarked, sent
  once, of the same segment size, sent at the same time and ending on a
  full segment. So the log after k per-segment passes of one step equals
  the log after one run, and a step of new data adds one range whichever
  way output cut it.

A run costs one `gb_trees` insert, as one segment does, so the send
log's 8.3 percent in `gb_trees` and 6.2 percent in `erx_tcp_sendlog` of
the connection's samples fall by the run's length.

### Each transport's cut

| Transport | Where a run is cut | Copies of a payload byte | Calls |
| --- | --- | --- | --- |
| `erx_virtio_net` (erXos) | `erx_device:post_frame/5`: the device NIF posts the run's frames from the first, each as one request in one pool buffer (the 12-byte `virtio_net_hdr`, then the frame), cut and summed through `erx_tcp_cut_frame` as it copies, until the queue has no free entry | one, into the pool buffer | one NIF call and one doorbell per run |
| `erx_netmap` (a host) | its NIF's `send/2`: the core plans the run's slots from one snapshot of the ring, syncs at most once when it is full, and cuts each frame into its slot's buffer | one, into the slot | one NIF call per run; one sync per flush |
| `erx_tap` (a host) | its NIF's `send/2`: each frame's headers go to the NIF's scratch through `erx_tcp_cut_header`, which sums the payload slice where it lies, and one `writev` hands the kernel the headers and the slice | one, the kernel's; the payload is read once more to sum it | one NIF call per run, one system call per frame |
| `erx_net_pipe` (`udp`, `process`) | the frame layer, `erx_net_frame:cut/1` | none of the stack's: `gen_udp` copies into the kernel, and a test process shares the binaries | Erlang work per frame |
| `erx_net_loop` | the frame layer, as for the pipe | none | Erlang work per frame |

A transport that has room for fewer frames than a run holds takes the
first ones and answers `{ok, N}`. The driver keeps the rest in its
backlog as `erx_net_frame:run_tail(Run, N)`, the same run with its
sequence number advanced and its payload starting `N * seg` bytes later,
so a run never waits whole for room that is partly there. The transmit
credit's units for the frames still in the backlog stay reserved, as for
any frame there.

The same calls take a frame that is not a run (an irregular segment,
ARP, ICMP, UDP) as iodata that the C walks itself, at most 64 binaries,
with or without the checksum design's delayed checksum. So no transport
joins a frame's binaries in Erlang
([design-runtime.md](design-runtime.md#the-device-nif)).

### Device segmentation

virtio-net's `VIRTIO_NET_F_HOST_TSO4` and `VIRTIO_NET_F_HOST_TSO6` let
the device take one request of up to 64 KiB whose `virtio_net_hdr` names
`gso_type`, `hdr_len`, `gso_size`, `csum_start` and `csum_offset`, and
cut it itself (virtio 1.2, section 5.1.6.2), as FreeBSD hands a capable
interface a TSO segment marked `CSUM_TSO` with its `tso_segsz`
(`tcp_output.c:1398-1406`). A run maps onto that header field for field.
The device path needs `VIRTIO_NET_F_CSUM` as well, a transmit queue
whose buffers hold 64 KiB or chains across buffers, the header's fields
in `abi/formats/virtio.txt`, and the bits in `negotiate/2`'s wanted set.
It saves the guest the per-frame header work and descriptors, not the
copy, since no binary ever aliases memory a device can reach (R9 of
[design-runtime.md](design-runtime.md#invariants)); on QEMU the host
process then does the cutting. It is an extension ([Open
decisions](#open-decisions), 3).

What QEMU offers was checked only in part. QEMU 11.1.3 on the
development host (Homebrew) lists, for `qemu-system-aarch64 -device
virtio-net-device,help`, the properties `csum`, `gso`, `host_tso4`,
`host_tso6`, `guest_csum`, `guest_tso4`, `guest_tso6` and `mrg_rxbuf`,
each defaulting to on. Whether the device offers those bits to a guest
when its peer is a hub port, as the harness's is (`tools/lib/erx/qemu.rb`:
`hubport` netdevs joining `user` and `dgram`), was not checked, since
QEMU's source was not at hand. QEMU's `virtio_net_get_features` is
believed to clear the offload bits when the peer carries no virtio-net
header, and a hub port carries none, so the harness's device would offer
none of them; this is unverified. The transport logs at each start which
finisher it took, `finish copy` or `finish device`, so every measurement
records the path it used.

The receive offloads, `VIRTIO_NET_F_GUEST_CSUM`, `GUEST_TSO4`,
`GUEST_TSO6` and `MRG_RXBUF`, are never negotiated: each is a device
claim the stack would have to believe, and the merge does their work on
bytes the stack holds.

## Receiving

### The merge

A frame is a merge candidate when all of these hold:

* it is Ethernet II without a VLAN tag, with EtherType IPv4 or IPv6;
* an IPv4 frame has a 20-byte header (`tcp_lro.c:276`), is not a
  fragment (`:279`), carries protocol 6, and its total length fits the
  frame, any bytes after it being the padding of a 60-byte frame; an
  IPv6 frame has next header 6, so no extension header, and a payload
  length that matches the frame;
* its IPv4 header checksum and its TCP checksum are correct, from the
  frame's network sum, the copy's
  ([Checksums in the copy](design-network-stack.md#checksums-in-the-copy)),
  or one the merge computes when the frame came without one. FreeBSD
  merges only frames whose checksums the hardware has validated
  (`tcp_lro.c:1303-1313`); the copy's sum stands for the hardware here;
* the TCP header has ACK set and no flag but ACK and PSH
  (`tcp_lro.c:1006-1014` and `:1050-1053`), so no SYN, FIN, RST, URG, ECE
  or CWR, and a data offset of 5, or of 8 with exactly the timestamps
  option in FreeBSD's layout (`:996-1005`, `TCP_LRO_TS_OPTION`).

A candidate joins the open unit of its flow when all of these hold:

* **The same flow:** the same link addresses, IP version, addresses,
  ports, header length, and type-of-service or traffic-class byte, and
  for IPv6 the same flow label. FreeBSD does not compare the
  type-of-service byte; the stack does, so that a CE mark on one segment
  is never merged away and ECN sees every mark.
* **In order:** its sequence number is the unit's next (`tcp_lro.c:1065`).
* **The acknowledgement moves forward:** its ACK is at or past the
  unit's, and a frame without payload joins only when its ACK passes the
  unit's. FreeBSD ends a unit at a duplicate ACK (`:1068-1070`) and merges
  a pure window update whose window grew (`:1081-1085`). The stack passes
  on alone every pure ACK that does not advance, a duplicate and a
  window update alike, because each carries a fact, a duplicate's count
  or a window, that a merged unit would hide, and one rule covers both.
* **Timestamps move forward:** its TSval is at or past the unit's
  (`:1054-1063`).
* **The size fits:** the unit's payload stays within FreeBSD's
  `TCP_LRO_LENGTH_MAX`, 65,280 bytes (`tcp_lro.h:200`), so the merged
  segment fits one IP packet.

Up to eight units are open at once, one per flow, FreeBSD's
`TCP_LRO_ENTRIES` (`tcp_lro.h:41`); a candidate of a ninth flow closes the
oldest unit. A frame that is not a candidate, or a candidate that cannot
join its flow's unit, first closes that flow's unit, as FreeBSD's
`tcp_push_and_replace` flushes an entry (`tcp_lro.c:903`), so a flow's
frames keep their order; such a candidate then opens a new unit. Every
unit closes at the end of the call. Nothing of one batch waits for the
next, so the merge keeps no state between calls and nothing has to time
out, where FreeBSD keeps entries across calls and flushes them on a timer
(`tcp_lro_flush_inactive`).

Each unit, and each frame on its own, stands in the output where its
first frame stood in the input. A unit of one frame is that frame. A unit
of several is `{merged, N, First, Last, Payload}`: its first and last
frames as they arrived, each with its sum, and every member's payload as
a sub-binary, in order; the pure ACKs a unit holds have no payload and
are counted in N alone. Every Ethernet frame leaves the merge with its
network sum: a frame that came without one, from a transport whose copy
does not sum, is summed by the merge, which reads it to check its
checksum anyway. So `verify/1` always has a sum for a frame, and summing
in `verify/1` is left only for what never passes the merge, loopback
packets and reassembled datagrams.

The interface classifies a unit by its first frame, reserves room for N
segments ([Credit counts segments](#credit-counts-segments)), verifies
the first and the last frame as it verifies any frame, checks that the
last names the first's flow, and hands the connection one segment: the
first frame's header with the last frame's acknowledgement, window and
timestamps, the payload pieces, and N.

### A merged segment in TCP

TCP's segment record carries a payload as a flat list of binaries with
its length, `#seg{data :: [binary()], len, nsegs}`, a list of one binary
for an unmerged segment. Trimming, reassembly and delivery work on pieces
(`erx_tcp_payload:part/3` and `size/1`, pure), so no stage joins them;
the receive queue holds pieces, and a delivery's bytes become one binary
once, in the socket process, where `gen_tcp`'s API needs one
([The socket process](design-network-stack.md#the-socket-process)).

The connection takes a merged segment as FreeBSD's `tcp_do_segment`
takes an LRO packet:

* **The count.** `cc_ack_received` limits window growth to `nsegs` times
  `tcp_abc_l_var` segments (`tcp_input.c:290-314`, `nsegs` taken from the
  packet at `:1534`; RFC 3465), and the stack passes N as `#cc_ack.nsegs`,
  which `erx_tcp_cc` already reads. FreeBSD's LRO counts only the data
  segments it merges (`tcp_lro_mbuf_append_pkthdr`, `tcp_lro.c:937-960`)
  and drops the pure ACKs it merges uncounted (`:1088-1091`), so a run of
  pure ACKs reaches congestion control as one. The stack counts each
  merged ACK, so a sender's window grows as the separate ACKs would have
  let it. N also counts segments received in the connection's
  statistics.
* **The acknowledgement.** `DELAY_ACK` delays only a segment of at most
  `t_maxseg` (`tcp_input.c:511`). A merged data segment is longer, so it
  is acknowledged at once, as FreeBSD acknowledges an LRO packet and
  Linux a GRO one. Inside a merged segment the receiver sends fewer ACKs
  than RFC 5681's "at least every second full-sized segment" (section
  4.2). No ACK is made for a point inside it: one naming an inner
  boundary would be a guess, and one repeating the final value would be a
  duplicate the sender counts toward loss.
* **Timestamps.** The last segment's TSval and TSecr, as FreeBSD stores
  them, so `ts_recent` takes the last TSval and the ACK echoes it, and the
  round-trip sample is taken from the last echo.

What the merged segment does not carry, and why that is acceptable: one
round-trip sample per unit instead of one per ACK, the latest; the
acknowledgement values inside a unit, which the last covers; and the
per-segment `ts_recent` updates. A unit's TSvals do not decrease, so PAWS
judges it by its newest; an old duplicate merged in front of fresh
segments passes, as it does under FreeBSD's LRO. Each of these is what
FreeBSD with LRO does.

### Credit counts segments

A merged segment takes one unit of its connection's credit for each
segment it holds, and one token of the interface's ingress bucket for
each, so a connection's credit still bounds the bytes queued for it by
its limit times one frame, merged or not
([Credited queues](design-network-stack.md#credited-queues)). The
interface checks N against what it can see before it charges it
([What the stack believes](#what-the-stack-believes)).

## The lean step

Runs divide the step's cost on bulk traffic. A run of one, a request or a
reply, still pays the step alone, so the step itself has to cost a
quarter or less of what it does. Every change below keeps the core a set
of pure functions.

### Where a segment's cost goes

The connection's samples while sending, by module (tprof, 64 MiB; shares,
since tprof inflates small functions), against the change that removes
each:

| Share | Where | Change |
| --- | --- | --- |
| 14.6% | `erx_tcp_output` | a run per pass; output's fast case |
| 12.4% | `erx_tcp_input`, ACKs | header prediction finishes the pure ACK |
| 10.3% | `erx_tcp_wire`, headers and options | the template; runs |
| 9.5% | `lists` (stage lists, folds, `min`) | finished fast paths; actions built once |
| 8.3% + 6.2% | `gb_trees` and `erx_tcp_sendlog` | the send log keeps runs |
| 6.0% | `erx_tcp` | the hot control block |
| 3.9% + 3.1% + 3.4% | `erx_net_frame`, `erx_bytes`, BIFs | the template; the copy sums |
| 3.0% + 2.1% | `erx_tcp_conn`, `erx_net_credit` | one step per mailbox |

The minor collections, about a tenth of the connection's time, fall with
the allocation.

### The control block, hot and cold

Updating a record copies all of it, so the 78-field `#tcb{}` costs 79
words at every stage that changes a field. It splits in two:

* `#tcb{}` keeps what a data segment or an acknowledgement of an
  established connection changes: the sequence variables, the windows,
  the timestamps' recent value, the estimators, the congestion state, the
  send log, the buffers, the timers, the waiting callers and the
  per-step requests, about 38 fields;
* `#tcb_conf{}`, one field of `#tcb{}`, holds what only the handshake,
  an option, a path change or the owner's requests change: the
  addresses and ports, the initial sequence numbers, the negotiated
  options, `t_maxseg`, the modules of congestion control and loss
  detection, the buffer limits, keepalive's parameters, `nodelay`,
  `linger` and the ending's errors.

The split follows one rule: a field goes into `#tcb_conf{}` when no step
that sends or takes data on an established connection writes it.
A stage that changes nothing returns the record it was given.

### Header prediction finishes its cases

FreeBSD's header prediction (`tcp_input.c:1731-1950`) applies the
effects of its two common cases itself: a pure ACK of new data and
in-order data that acknowledges nothing new. The stack's header
prediction takes the same two cases with FreeBSD's preconditions, and
finishes each in one function that builds the next control block once:

* **The pure ACK:** `snd_una`, the send buffer's drop, the send log's
  acknowledgement, the round-trip sample, `cc_ack_received` with the
  segment's count, the retransmission timer, `snd_wl2`, and the waiting
  writer;
* **in-order data:** `rcv_nxt`, the delivery, the delayed ACK or the ACK
  now, `ts_recent` and the receive window.

Each function does what the general stages do from `ack` on for its
case, not what FreeBSD's shorter fast path does, which leaves `snd_wl1`,
`rcv_up` and `t_dupacks` differently
([design-network-stack.md](design-network-stack.md#events-and-the-step)).
So each effect has two implementations, the general stages and the
finished case, and one meaning: the stack's property test of header
prediction, which runs every segment header prediction accepts, and its
near misses, through the general stages and requires the same state and
actions, compares the two implementations. The general stages stay for
every other segment and as the oracle. Merged segments take the fast
path too, since a unit is in-order data or a pure ACK by construction.
Output has the same shape: in the established steady state (no
recovery, an open window, no SACK information, nothing irregular) one
pass decides, makes a run and commits it with one update of the control
block.

### One step per mailbox

A connection whose mailbox holds 13 items steps them 13 times, and pays
the loop each time: the configuration generation, the clock's hint, the
credit's atomics and the `gen_server` dispatch. Before it steps an
`{items, Interface, Items}` message, the connection takes every further
`{items, _, _}` message already in its mailbox, takes their units from
its credit, and steps all their segments as one `{segments, Segments}`
event, in arrival order. The credit bounds what can wait, so it bounds
the batch too. An idle connection steps each message as it arrives, so
the batch adds no latency; under load it grows by itself. One step over
many segments ends with one output pass, so ACKs that per-message steps
would send apart leave as one, the acknowledgement count of FreeBSD with
LRO.

A step that raises over a batch is handled as a step that raises over
one message: the connection ends itself from its state before the batch
and exits with the exception ([What fails and what
survives](design-network-stack.md#what-fails-and-what-survives)). The
batch's messages end with it, as the connection's other queued messages
do, so draining needs no rule of its own for a bug.

The receive queue holds pieces: `{deliver, Data}` appends the pieces to
it and copies out only those smaller than a quarter of the binary they
reference, the stack's rule (`erx_tcp_conn:compact/1`), so no step joins
payload.

### The core stays pure

Each change keeps decisions in pure functions and effects at the edge.
The finished fast paths are pure functions beside the general stages
they equal. The template is a value in the connection's state, made by a
pure function of the path and the negotiated options and made again when
those change. The run is a value output returns; the copy that cuts it
decides nothing that output did not decide, and the merge's grouping is
a pure function of a batch, with an Erlang model as its specification.
The step's inputs and outputs stay values, and every new piece is tested
on the host against the slower function it replaces.

### What the lean step is expected to give

These are estimates from the measured shares, to be replaced by
measurements ([Verification](#verification)). For a run of one, the
connection's work falls from about 330 calls and 1,400 heap words to
about 80 calls and 300 words, and its time from 12.3 us to 3 to 4 us,
three to four times less. The lean step alone is not enough for the bulk
target, and runs are not enough for the small-segment target; the two
together are the design. On bulk traffic, with runs of about 45 frames
and merged units of 10 to 40 segments, the connection's share per segment
falls below 0.5 us, and the limit moves to the copy and the medium's
system calls.

## Processes and batching

**What stays a process.** The driver, one per interface, owns its medium
(the device queues or the NIF handle), its credits, its backlog and its
link state, and restarts with its medium. The interface owns
classification, neighbours, addresses and reassembly, and the merge.
The connection owns its TCP state, and the socket process, in the
owner's domain, the owner's view of the socket. Each keeps the one role
the stack's design gives it
([One owner, one step](design-network-stack.md#one-owner-one-step)), and
no state moves between them.

**What becomes a call.** The tap helper's relay, an operating-system
process with a pipe on each side, becomes the tap NIF that the driver
calls ([The seam](#the-seam)). Framing, cutting, merging and summing are
calls in the process that holds the bytes.

**Batching per message.** Every hop carries all its sender holds: the
driver one `{frames, ...}` message per transport batch, up to 64 KiB;
the interface one `{items, ...}` message per destination per batch; the
connection one `{transmit, ...}` message per step, holding runs. Every
receiver steps everything that waits for it, bounded by its credit: the
connection every queued `{items, ...}`, the interface every queued
`{frames, ...}`, the driver every queued `{transmit, ...}` before it
posts.

**Batching per write.** One NIF call per run, and per plain frame, on
every transport with a copy of its own; one doorbell per call on virtio;
one sync per flush on netmap; one `writev` per frame on tap, because a
tap device takes one frame per write.

**The scheduler spread.** Fewer hops per byte mean fewer wakes per
byte: with runs of about 45 frames and merged units of about 20
segments, a bulk segment costs under a tenth of a hop where it costs
about two. On erXos the network domain's runtime runs as many
schedulers as its CPU grant allows, at most 32, and parks without
spinning by default
([design-runtime.md](design-runtime.md#configuration)).
On a host the stack depends on no scheduler setting, and the benchmarks
record the setting and report CPU per byte both at the default and at
`+S 4:4`. ERTS's run-queue binding, the undocumented `scheduler` option
that `erl_process.c` parses for `spawn_opt` and `bif.c` for
`process_flag/2`, could keep a driver and its interface on one
scheduler; it is a suspected saving on the watch list, not part of this
design ([todo-performance.md](todo-performance.md)).

**What does not change.** A received segment still passes the driver and
the interface before its connection. For bulk traffic that is one hop
per batch. For request-reply it is one message, about a microsecond.
Letting the driver classify over the interface's published view, or
running the transport inside the interface, would remove it, at the
price of the medium's isolation from the interface's state; the
request-reply benchmark's profile decides whether that is worth it, and
the question is on the watch list.

**Pieces and credit of the socket process.** The socket process sends a
`gen_tcp:send/2` in pieces of at most 64 KiB, one at a time
([Message sizes](design-network-stack.md#message-sizes)); each piece lands
in the send buffer as one binary, and a run of at most 65,535 bytes covers
at most the end of one piece and the start of the next. A connection
pushes received bytes within the credit the socket process granted, at
most a piece per push. A merged segment's payload, at most 65,280 bytes,
fits a piece. A push carries the receive queue's pieces as they are, and
the socket process joins them into one binary when it hands the owner
data, once per delivery, in the owner's domain. The socket protocol's
push carries `{data, [binary()]}`, a flat list of at most 64 binaries
([Message sizes](design-network-stack.md#message-sizes)).

## Copies

Copies of a payload byte after this design, by path and medium:

| Path | Medium | Copies | Total |
| --- | --- | --- | --- |
| send | virtio, erXos | the lane's two, from the owner's domain into the network domain; the cut, into the pool buffer | 3 |
| receive | virtio, erXos | `complete/3`, into a binary; the lane's two, into the owner's domain; the socket process's join when a delivery holds more than one piece | 3 to 4 |
| send | tap, a host | the kernel's write; the payload is read once more to sum it | 1 |
| receive | tap, a host | the kernel's read, summed as it is kept; the join, as on erXos | 1 to 2 |
| send | netmap, a host | the cut, into the slot | 1 |
| receive | netmap, a host | the NIF's copy, into a binary; the join, as on erXos | 1 to 2 |

The per-segment stack over p620's tap copies a byte four times sending
and five times receiving. On erXos the counts change little: what the
design removes there is per-segment work and the virtio transport's
frame join, and `recv`'s join of the receive queue moves from the
connection to the socket process. Placing the merge inside
the device NIF's copy would make a merged payload contiguous there and
save the receive join on erXos, at the price of a parser of device-written
bytes in the device NIF ([Alternatives considered](#alternatives-considered)).

The rule holds by construction where it can: a payload byte the stack
holds is in a binary the owner, the lane or the medium's copy made, or a
sub-binary of one. Every other copy is at a listed site. A source check
in `make check` reads the modules a TCP payload passes through (the
`erx_tcp_` modules, `erx_net_frame`, `erx_net_tx`, `erx_net_driver`,
`erx_net_if`, `erx_net_input` and the transports) and fails the build on
any call of `iolist_to_binary/1`, `list_to_binary/1`, `binary:copy/1,2`,
`binary:list_to_bin/1` or `erlang:iolist_to_iovec/1` outside its list.
The list has three entries: the receive and reassembly queues' copy of a
small piece (`erx_tcp_conn:compact/1`, `erx_tcp_reass`), which keeps a
few bytes from holding a frame alive; the pipe's `process` end, whose
far end, a test, takes each frame as one binary; and the loop
transport's copy of each packet it returns, the one copy a device makes
elsewhere ([The driver](design-network-stack.md#the-driver)). IP fragmentation
and reassembly, which a datagram's layout forces, and the socket
process's join, in `erx_net_client`, are outside the modules it reads.
A seeded violation in its test shows the check catches a new site.

## The seam

A driver tells the interface, once, at attach, who finishes the frames
the stack leaves unfinished: a delayed checksum and a run's cut. This is
the `finish` key of
[Checksums in the copy](design-network-stack.md#checksums-in-the-copy),
which covers both, since one copy does both:

```erlang
%% erx_net_driver: the link information a transport answers at init
-type link_info() :: #{..., finish := copy | device | none}.

%% erx_net_driver: a transport's transmit callback
-callback transmit(erx_net_frame:frame() | erx_net_frame:run(), T) ->
    {ok | {ok, Taken :: pos_integer()} | full | {drop, Reason :: atom()}, T}.
```

`copy` means the transport's copy finishes them, `device` the device (an
extension), and `none` nobody below the stack, so the frame layer cuts
runs and finishes checksums itself. The interface writes `finish` into
its row with the MTU, from the attach's one answer, so it has one source.
Output does not read it: every path gets runs, and only the frame layer
asks who cuts them. `{ok, Taken}` is a run partly taken.

Receiving has no capability to state: every transport hands up frames,
with their network sums when its copy sums, and the interface merges
every batch whichever transport made it.

| Transport | `finish` | Cut | Received frames | Merged |
| --- | --- | --- | --- | --- |
| `erx_virtio_net` | `copy`; `device` with `VIRTIO_NET_F_CSUM`, `HOST_TSO4` and `HOST_TSO6`, an extension | `erx_device:post_frame/5` | `{sum, S, Frame}`, from `complete/3` | in the interface |
| `erx_netmap` | `copy` | its NIF's `send/2` | `{sum, S, Frame}`, from its NIF's `recv/1` | in the interface |
| `erx_tap` | `copy` | its NIF's `send/2` | `{sum, S, Frame}`, summed by its NIF after the kernel's read | in the interface |
| `erx_net_pipe` | `none` | `erx_net_frame:cut/1` | `Frame`; the merge sums it | in the interface |
| `erx_net_loop` | `none` | `erx_net_frame:cut/1` | `{Zone, Packet}` | never: the loopback carries IP packets, not Ethernet frames |

`finish` is not configured: each transport answers it from what its
medium offers. The pipe's `process` end answers `copy` only in its
offload mode, a test configuration that cuts through the C core
([Tests](#tests)).

**The tap transport.** `erx_tap`, in `portable/` beside `erx_netmap` and
never in an erXos image, drives a host's tap device through a NIF of its
own, `erx_tap_nif`, in place of a port program between the node and
the tap. It is the netmap transport's construction
over a file descriptor, without shared memory: each call does a bounded
amount of work on a normal scheduler, each direction has exactly one
wake, and the kernel's copy is the only copy of a payload byte. The
stack's design specifies it
([The tap transport](design-network-stack.md#the-tap-transport)). The
tap's virtio-net header (`TAPSVNETHDR`, `sys/net/if_tap.h:58`) is not
used; what its offloads would do across `bridge0` and an `epair` was not
checked.

## What the stack believes

* **The cut** reads only the stack's own values: the template, the
  integers and sizes Erlang chose, and payload bytes it does not
  interpret. It checks all of them and refuses a bad run with `badarg`,
  which only a bug of the stack makes, and it never reads memory a device
  can write. A wrong cut makes the peer drop frames or receive wrong
  bytes, and cannot write outside the buffer the plan checked.
* **The merge** reads untrusted bytes, frames a device or a host's kernel
  wrote, but only in binaries the copy made, which nothing changes. It
  checks every length against its binary with checked arithmetic,
  creates nothing but tuples, lists and sub-binaries of its input, and
  decides only which frames belong together. The stack believes three
  claims of it: that the middle frames of a unit belong to the first
  frame's flow and follow it in order, that each has correct checksums,
  and that the payload pieces are those frames' payloads. Erlang does not
  check them per frame, which is the point; the merge's model and the
  oracle of its fuzz target do ([Verification](#verification)). A bug in
  it can deliver wrong bytes within the flows it sees, as any bug of the
  stack can, but cannot read outside a binary.
* **What Erlang re-checks.** The first and last frames of a unit pass
  `classify/2` and `verify/1` like any frame, IPv4 header checksum and
  every length included, and every value TCP acts on is decoded from
  them. The interface checks that `length(Payload) =< N =< 256` and that
  the pieces' total plus the first frame's headers fits one IP packet,
  and drops a unit that fails as `malformed`; only a merge bug makes one.
  It charges N units of credit, so a count the merge understated would
  still be bounded by the piece count Erlang sees, and a count it
  overstated costs only credit. `cc_ack_received` grows the window by at
  most the bytes the ACK acknowledges whatever the count
  (`tcp_input.c:290-314`), so an inflated N cannot inflate the window.
* **Device claims.** None is believed: virtio's receive header is never
  read, the receive offloads are never negotiated, and tap and netmap
  give none.
* **A residual of Phase 1.** On the stopgap the virtio driver and the
  stack run in the system domain (plan.md's 1b-G), so the merge's C runs
  in the system domain's runtime, where a memory error is a fault of the
  system domain and resets the machine. Development builds run trusted
  code only; the residual is in `TODO.md` until the network domain holds
  its device.

## Concurrency and failure

No process, lock or shared state is added. The cut runs inside the
driver's NIF call, the merge inside the interface's call, and each
finishes within its call: the cut at one run (at most 65,535 bytes, 64
pieces and 45 frames at a 1,500-byte MTU), the merge at a driver's
batch, 256 frames and 64 KiB, and both charge reductions for the bytes
they read. The merge closes every
unit when its call returns, so nothing is held between calls.

* **A run partly taken** waits in the driver's backlog as its tail, with
  its credit, and leaves at the transport's next `writable` event, as any
  frame there does.
* **A medium that ends** drops the backlog, runs included, each frame
  counted, as the driver drops any frame it holds; the send log recovers
  them as losses, as it recovers frames lost on a wire.
* **A step that raises** over a drained batch ends the connection from
  its state before the batch, as a step over one message does
  ([One step per mailbox](#one-step-per-mailbox)).
* **Order.** A flow's segments keep their order through the merge, and a
  unit stands where its first frame arrived; frames of different flows
  may change places, as FreeBSD's LRO flushes them. A connection's runs
  leave in the order output made them, through one driver.
* **Credit.** A run takes one transmit unit per frame and a merged
  segment one receive unit per segment, so every queue stays bounded as
  the stack's design states.

## Refusals and error results

* `erx_tcp_cut_plan` refuses with `ERX_EINVAL` a template that is not
  one the stack makes, a zero segment size, more than 64 pieces, or a
  run over `IP_MAXPACKET`; the NIFs answer `badarg`. Only a bug of the
  stack reaches it.
* `erx_device:post_frame/5` answers `{ok, N}` for N frames posted,
  `{error, full}` with nothing posted when no entry is free, and
  `{error, broken}` as `post/4` does; `badarg` as above.
* The netmap and tap NIFs' `send/2` answer `{ok, N}`, `full` with the
  descriptor armed, `{drop, malformed}` or `{drop, too_long}` for a
  plain frame, and `{error, Reason}`, which ends the medium, as the
  netmap design defines them.
* A transport whose `finish` is `none` drops a run it is given as
  `malformed` and counts it; only a framing bug makes one, since the
  frame layer cuts runs for such a transport.
* `erx_bytes:tcp_merge/1` answers `badarg` for a list of more than 256
  frames or 64 KiB, or an element of another shape. It refuses no frame:
  a frame it cannot merge passes on alone, and one whose checksum fails
  passes on alone for `verify/1` to drop and count as `bad_sum`, so that
  count has one place.
* The interface drops a merged unit whose count or size fails its checks
  as `malformed`.

## Verification

Each test is paired with a seeded fault it must catch.

### Tests

1. **The cut equals the reference.** A host property test, through a
   test NIF over `erx_tcp_cut.c`: random runs (IPv4 and IPv6, with and
   without timestamps, PSH and FIN, segment sizes, payloads split into
   random pieces, partial tails) cut by the C give byte for byte the
   frames of `erx_net_frame:cut/1`. *Seeded faults:* PSH kept on every
   frame; the sequence number advanced by `seg - 1`; the IPv4 checksum
   computed before the last frame's length is stored.
2. **Output with runs equals output per segment.** A property test of
   the TCP core, and the explorer's runs ([The TCP core: exhaustive
   exploration](design-network-stack.md#the-tcp-core-exhaustive-exploration)):
   over random event sequences, a core that makes runs and one held to
   runs of one emit the same frames once both are cut by the reference,
   and end in the same control block, the send log compared range by
   range. *Seeded faults:* a run allowed while a D-SACK block is owed; a
   run not trimmed to whole segments; a run's RTT probe started at its
   last frame instead of its first.
3. **The send log's rules.** A property test over random runs, SACK
   blocks and acknowledgements: the log of k per-segment sends equals
   the log of one run, and no range boundary falls inside a segment.
   *Seeded faults:* a SACK block that splits a segment; the extension
   rule taking a range of another segment size.
4. **The merge equals its model.** `erx_tcp_merge_model`, an Erlang
   model written from `tcp_lro_condense`'s rule as this document states
   it, against the C over random batches: interleaved flows past eight,
   gaps, every flag, other options, differing type of service, bad
   checksums, duplicate ACKs, window updates, padding. Unit by unit the
   outputs are equal. *Seeded faults:* a merge across differing type of
   service; a unit's first frame with a bad TCP checksum accepted; a
   pure ACK that does not advance merged.
5. **Merged input against per-segment input.** A property test of the
   core: the same bytes stepped as merged segments and as single ones
   give the same delivered bytes, `rcv_nxt`, `snd_una` and send log; the
   ACK after a merged segment carries the ACK value of the per-segment
   run's last ACK; after a slow start of merged ACKs the congestion
   window is within one segment of the per-segment run's. *Seeded
   fault:* N not passed to `cc_ack_received`, which leaves the window
   short by more than the bound.
6. **Header prediction equals the general stages.** The existing
   property test, which requires the general stages' control block and
   actions for every segment header prediction accepts, run against the
   finished cases. *Seeded fault:* the fast pure ACK not restarting the
   retransmission timer.
7. **One step per mailbox.** A connection with five queued `{items,
   ...}` messages, each holding one in-order data segment, steps once,
   sends one ACK covering all five and takes five units from its credit.
   *Seeded fault:* the drain stopped after the first message, which
   sends more than one ACK.
8. **Credit counts segments.** A peer that sends a connection in-order
   data in bursts the merge merges, faster than the connection steps,
   never has more than the credit limit's worth of frames queued at the
   connection. *Seeded fault:* one unit per merged segment, which lets
   the queue exceed the bound.
9. **The device NIF.** On the hosted backend's model device: a run
   posted as N requests whose bytes equal the cut's frames; a full queue
   that takes a run's first frames, and the tail that later posts the
   rest. *Seeded fault:* the tail posted from frame 0, which the byte
   check catches.
10. **The tap NIF.** Over a `socketpair(AF_UNIX, SOCK_DGRAM)`, which
    keeps one frame per `read` and `write` as a tap does: a run written
    whole, a run cut short by a full socket and finished at the
    `writable` event, and a receive batch of 64 frames with their sums.
    *Seeded fault:* `EAGAIN` in the middle of a run answered as all
    taken, which loses frames the test counts.
11. **Packet scripts against FreeBSD.** The suite's scripts and erXos's
    own ([Packet scripts against
    FreeBSD](design-network-stack.md#packet-scripts-against-freebsd))
    run once more through the pipe's `process` end in its offload mode:
    its `finish` is `copy`, a host test NIF over `erx_tcp_cut.c` cutting
    the runs it is given, and it hands the interface the frames a script
    injects at once as one batch, so the merge sees bursts. Every
    verdict must equal the one through the plain `process` end and
    FreeBSD's. New erXos scripts inject bursts and check the merge's
    visible behaviour: one ACK per merged segment, echoing the last
    TSval, and a duplicate ACK, an ACK with SACK blocks, a FIN and a
    CE-marked segment each ending a unit. *Seeded fault:* the offload
    mode's batching turned off, so the count of units the interface
    merged stays at zero, which the runner requires to be above zero in
    that mode; and its cut turned off, so the count of runs the pipe cut
    stays at zero.
12. **The copy check.** The source check's seeded violation, an
    `iolist_to_binary/1` added to `erx_tcp_output`, fails `make check`.

### Fuzz targets

* **`tcp_cut`:** arbitrary templates, segment sizes and piece lists into
  `erx_tcp_cut_plan` and every frame of an accepted plan into a buffer of
  the planned size, under AddressSanitizer. Its oracle re-derives each
  frame's length, sequence number and checksum from the input. *Seeded
  fault:* the TCP header's length bound off by one, which the target
  must find within its budget.
* **`tcp_merge`:** arbitrary batches of up to 256 frames and 64 KiB,
  with and without sums, under AddressSanitizer. Its oracle checks every unit:
  the pieces are the members' payloads, contiguous in sequence, of one
  flow, each member's checksums correct, and every input frame in exactly
  one unit or output on its own. *Seeded fault:* a merge across differing
  ports, which the oracle catches.

Both land with their cores and run in `make check-fuzz` at the milestone
gate.

### Benchmarks and targets

Every number names the host, the operating system, the accelerator, the
QEMU version where there is one, the compiler and flags, the workload and
the baseline, and every measurement reports the counters of frames per
run, segments per merged unit and frames dropped. A bulk measurement
whose counters show no runs sent or no units merged fails, so the number
is known to come from the path under test.

* **Bulk on p620.** 512 MiB each way in 64 KiB sends, passive
  `recv(S, 0)`, the median of three, over the tap transport and over a
  VALE port of netmap; throughput, CPU seconds per GiB from the BEAM's
  `rusage`, and context switches. Baseline: lwIP 2.2.1 over the same tap
  (`~/erxos-history/net-bench-p620-lwip-2026-11-09/`) and over VALE (the
  netmap transport's pinned lwIP). *Target:* at least two thirds of
  lwIP's throughput each way over the same medium, 4.4 Gbit/s over tap.
* **Request-reply on p620.** One connection, requests and replies of 64
  bytes and of 1 KiB, an echo server in the jail, 10 s; transactions a
  second, median and 99th-percentile latency, CPU per transaction; and
  16 connections at once. Baseline: lwIP's bench program, given a
  request-reply mode, against the same echo server. *Target:* a rate of
  at least a third of lwIP's and CPU per transaction at most three times
  lwIP's.
* **`tools/erx bench net-bulk` and `tools/erx bench net-rr` under HVF.**
  An erXos guest and the Linux oracle guest on the path plan.md's gate
  GN-QEMU measures, with the same workloads. Baseline: the Linux oracle
  guest at both ends of the same path, which shows what the medium
  allows; lwIP is the baseline on p620 only, where it runs on the same
  medium. TCG numbers are not compared with these.

### What each part is judged by

Each part lands with the bulk and request-reply numbers on p620 before
and after it, and with the HVF numbers when it changes erXos's code. The
order of the parts and the gain each is expected to give are kept in
`TODO.md`.

| Part | Judged by |
| --- | --- |
| one step per mailbox, batching per hop | the connection's time per segment; ACKs per received segment; receive throughput |
| the lean step | the connection's calls, heap words and time per segment for a run of one; request-reply rate |
| the tap transport | CPU per GiB; the driver's time per frame; throughput once the connection is faster than the driver |
| runs and the cut | frames per run; the connection's time per sent segment; send throughput |
| the merge | segments per unit; the interface's and the connection's time per received segment; receive throughput and the sender's throughput, which merged ACKs serve |
| netmap with runs and the merge | the same over VALE, against lwIP over VALE |

## Open decisions

1. **C does per-frame work inside the copy and the merge.**
   [design.md](design.md#decisions) gives C the work done once per byte
   and Erlang the work done once per packet, and leaves native code for
   TCP's fast path to the measurement on erXos's kernel (gate GK3). The
   cut writes header fields per frame inside the copy's per-byte pass,
   and the merge reads per-frame headers and groups frames by a fixed
   rule. Neither makes a TCP decision: what to send and what a segment
   means stay in Erlang. *Recommended:* adopt it before GK3, on the p620
   evidence. The bottleneck shown there is the number of per-segment
   Erlang steps in one process, which does not depend on the kernel
   below. GK3 still decides whether any TCP decision needs native code.
2. **The tap transport becomes a NIF.** Sending, the helper took 11.9
   percent of all CPU samples on p620, against 62.7 for the BEAM, and a
   frame costs three system calls and four copies through it, where the
   lwIP baseline runs over the same tap with one copy in user space and
   one in the kernel. The spawn driver's 64 KiB read buffer, allocated
   and freed at every read (`ready_input` in `sys_drivers.c`), is the
   likely, unconfirmed, source of the 8 to 10 percent of kernel lock
   spinning under `munmap`. The NIF is the netmap transport's
   construction without shared memory. *Recommended:* replace the helper
   and the pipe's `port` end with `erx_tap`, and run the bulk benchmark
   over both tap and VALE.
3. **Device segmentation.** `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`
   need a queue of 64 KiB buffers or chains, new fields in the ABI file
   and a second finisher in the transport, save no copy, and are likely
   not offered on the harness's hub port. *Recommended:* an extension
   until a harness medium offers the bits, tested there against the
   copy. It shares the checksum design's open decision on
   `VIRTIO_NET_F_CSUM`.

## Alternatives considered

* **The lean step alone.** Removing the measured per-segment costs gives
  about twofold, not the sixfold the gap needs.
* **TCP's established path in C.** A NIF for the input and output of an
  established connection, as the stack's design allows for one measured
  function, would make two translations of FreeBSD's decisions in two
  languages and move protocol decisions into C. Runs get most of the
  gain with every decision left in Erlang.
* **The merge inside the copy.** The device NIF, the netmap NIF and the
  tap NIF could each merge as they copy, laying a unit's payloads end to
  end so that its payload is one binary. That saves the socket process's
  join on erXos, but it puts a parser of device-written bytes in the
  device NIF, which parses nothing a device wrote, needs a snapshot and a
  plan in each NIF to read each byte once, and on tap needs a `readv`
  layout, since the kernel's copy lands a frame before its header has
  been seen. One merge after the copy, over immutable binaries, is simpler
  and the same for every transport; the join it leaves on erXos is on the
  watch list.
* **The merge in Erlang.** Grouping frames in the interface in Erlang
  still costs per-frame Erlang work at line rate, the cost the merge is
  there to remove.
* **The merged payload joined in the merge.** Joining a unit's pieces
  into one binary in the merge would keep TCP's payload a binary, but it
  copies early: a delivery that spans several units joins again. Pieces
  joined once, at the API, copy each byte at most once.
* **Runs for retransmissions.** The cut is invisible on the wire, so a
  retransmitted range could leave as a run. FreeBSD's default,
  `tcp_sack_tso` 0, sends one segment at a time, and the stack follows
  its default.
* **Joining small sends as the send buffer takes them.** This bounds a
  run's pieces, as FreeBSD's `sbcompress` compacts mbufs, at the cost of
  a copy of the owner's bytes. The 64-piece bound ends a run instead and
  copies nothing; many tiny sends then make short runs, a cost on the
  watch list.
* **Receive offload by the device.** `GUEST_TSO4` and `MRG_RXBUF` would
  have the device merge, a claim the stack would have to take on trust,
  as the checksum design declines `GUEST_CSUM`.

## References

* FreeBSD 15.1 (`release/15.1.0-p6`), the release the stack's line
  references cite: `sys/netinet/tcp_output.c` (the TSO decision,
  `:514-565`; the burst bound, `:916-937`; whole segments, `:940-948`;
  the small-fragment rule, `:955-962`; the FIN after a burst, `:965-969`;
  PSH, `:1117-1123`; `CSUM_TSO` and `tso_segsz`, `:1398-1406`);
  `sys/netinet/tcp_sack.c:157` (`tcp_sack_tso`); `sys/netinet/tcp_lro.c`
  (`tcp_lro_rx_common`, `:1280-1426`; `tcp_lro_condense`, `:963-1106`;
  `tcp_lro_mbuf_append_pkthdr`, `:937-960`; `tcp_lro_update_checksum`,
  `:678`; `tcp_flush_out_entry`, `:790`; `tcp_push_and_replace`, `:903`);
  `sys/netinet/tcp_lro.h` (`TCP_LRO_ENTRIES`, `:41`; `TCP_LRO_LENGTH_MAX`,
  `:200`); `sys/netinet/tcp_input.c` (`cc_ack_received`, `:290-314`;
  `DELAY_ACK`, `:511`; `nsegs`, `:1534`; header prediction,
  `:1731-1950`); `sys/net/if_tap.h:58` (`TAPSVNETHDR`).
* Virtual I/O Device (VIRTIO) 1.2, section 5.1: the network device, its
  feature bits and `virtio_net_hdr`'s GSO fields (5.1.6.2).
* RFC 3465 (appropriate byte counting), RFC 5681 section 4.2 (ACK
  generation), RFC 6864 (the identification of atomic datagrams), RFC
  7323 (timestamps and PAWS).
* The measurements: `~/erxos-history/net-perf-p620-2026-11-09/` (commit
  `c4f9bf5`) and `~/erxos-history/net-bench-p620-lwip-2026-11-09/`
  (commit `8b22014`).
* [design-network-stack.md](design-network-stack.md): the stack, its
  checksum, netmap and socket-process designs;
  [design-runtime.md](design-runtime.md#the-device-nif): the device NIF;
  [design-domains.md](design-domains.md#flow-control): the lane's copies.
