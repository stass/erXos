# Research record: FreeBSD's netinet and netinet6 mapped to an Erlang network stack

A point-in-time report, dated 2026-11-07, of how FreeBSD's network stack
divides into what an Erlang stack translates, what it drops, how large
each part is, which licences cover it and what FreeBSD offers as a test
oracle. [design-network-stack.md](design-network-stack.md) rests on it.
Apart from the corrections below, made before it entered the tree, its
findings are not edited in place; a re-check gets a new record.

Source: FreeBSD src, tag `release/15.1.0-p6`, commit
`95719d8a895bf8170851e9844d9b4092b1d2b6fe` (the newest 15.x tag from
`git ls-remote --tags https://git.freebsd.org/src.git`; checked 2026-11-07).
A shallow, sparse clone of that commit (sys/netinet, sys/netinet6, sys/net,
sys/conf, sys/modules/{tcp,cc}, sys/*/conf, tests/sys/netinet*,
contrib/netbsd-tests/net, share/man/man4, release). Nothing from it was
built or run. Paths below are relative to the source tree's root. Line
counts come from a scratch Ruby script, not kept: "raw" is `wc -l`; "code"
drops blank lines and comments (a crude `/* */` and `//` stripper, good to
a few percent). The licence survey came from another scratch script that
reads each file's SPDX line.

**Corrections.** This record's citations were checked against the same
pinned source, by the design's author and again when the record entered
the tree, and the errors found were corrected, each marked
*(corrected)*: where the `cc_*` hooks are defined, the
line of `tcp_compute_initwnd`, the default of path MTU black-hole
detection, the directory of `tcp_hpts.c` and `.h`, where the
`SO_REUSEPORT` same-user rule lives, three facts about the syncache, the
line of `syncookie_mac`, and the ISN secret's reseeding.

Release notes are not in the src tree (they live in the doc repo), so claims about
"what the release says" are not verified; claims below rest on the source, the
kernel configs and the module Makefiles.

## 1. Which TCP stack is the default; RACK; BBR

* **Default is the original stack, named "freebsd".**
  `sys/netinet/tcp_subr.c:351-352` defines `tcp_def_funcblk` with
  `.tfb_tcp_block_name = "freebsd"`, and `tcp_subr.c:365` initialises
  `V_tcp_func_set_ptr = &tcp_def_funcblk`. Its `tfb_tcp_output` is
  `tcp_default_output` (`tcp_output.c:186`); its segment handler is `tcp_do_segment`
  (`tcp_input.c:1511`).
* **Default congestion control is CUBIC**: `sys/netinet/cc/cc.c:80-83`
  (`#define CC_DEFAULT "cubic"` unless the kernel config says otherwise;
  `sys/conf/NOTES:672` shows the option).
* **RACK is built but not loaded.** `sys/modules/tcp/Makefile` lists `hpts`, `bbr`,
  `rack` (and `tcpmd5`) as subdirectories whenever INET or INET6 is on, so
  `tcp_rack.ko`, `tcp_bbr.ko` and `tcphpts.ko` are built as modules.
  `sys/amd64/conf/GENERIC` and `sys/arm64/conf` contain no `TCPHPTS`, `TCP_RACK` or
  `TCP_BBR` option (grep found none), so they are not compiled into the kernel. A user
  loads them (`tcp_rack_load="YES"`) and picks one with
  `net.inet.tcp.functions_default=rack` (`share/man/man4/tcp_rack.4`,
  `tcp_bbr.4`). Both modules `MODULE_DEPEND` on `tcphpts`
  (`rack.c:24671`, `bbr.c:14824`). GENERIC does set `TCP_OFFLOAD`, `TCP_BLACKBOX`,
  `TCP_HHOOK`, `TCP_RFC7413` (`sys/amd64/conf/GENERIC:38-41`).
* **BBR is v1 and only lightly maintained as far as the tree shows.** It is Netflix's
  port of Google BBR v1 (`bbr.c:1`, "Copyright (c) 2016-2020 Netflix"; a tunable text at
  `bbr.c:1355` says "close to google V1.0"). The man page is dated 2023-12-17
  (`tcp_bbr.4`), cites the 2016 ACM Queue paper and a university evaluation. I found no
  deprecation or "experimental" notice in `bbr.c`, `tcp_bbr.h`, the man page or the
  module Makefile. I cannot see commit history (shallow clone), so "maintained" is
  unverified; the shallow tree shows no BBR v2/v3.
* **RACK is the heavily developed one**: man page `tcp_rack.4` dated 2024-03-18,
  `rack_pcm.c` is a newer addition, and `tcp_rack.4` describes RACK-TLP (RFC 8985)
  plus pacing.
* Important: **neither alternative stack is a plugin over the default stack**. Each
  replaces the whole input and output paths (see section 3).

## 2. Sizes (lines of C)

### Default stack ("freebsd" function block)

| File | raw | code |
|---|---:|---:|
| tcp_input.c | 4191 | 2618 |
| tcp_output.c | 2179 | 1355 |
| tcp_timer.c | 973 | 637 |
| tcp_subr.c | 5056 | 3860 |
| tcp_syncache.c | 2587 | 1690 |
| tcp_sack.c | 1200 | 722 |
| tcp_usrreq.c | 3015 | 2385 |
| tcp_reass.c | 1115 | 768 |
| tcp_timewait.c | 354 | 223 |
| tcp_seq.h | 100 | 35 |
| **Core subtotal (the ten above)** | **20770** | **14293** |
| tcp_ecn.c (AccECN and classic ECN) | 612 | 423 |
| tcp_hostcache.c | 845 | 579 |
| tcp_fastopen.c | 1219 | 838 |
| **Subtotal with ECN, host cache, TFO** | **23446** | **16133** |
| headers: tcp_var.h, tcp.h, tcp_timer.h, tcp_fsm.h, tcp_syncache.h | 2640 | 1752 |
| not wanted: tcp_log_buf.c 3352/2263, tcp_lro.c 1492/1072, tcp_stats.c 271/201, tcp_offload.c 231/158 | 5346 | 3694 |

Note: `tcp_timewait.c` is small in 15 because a time-wait connection is a tcpcb in a
state, not a separate structure (see `tcp_twstart`, `tcp_timewait.c:148`).

### Congestion control (`sys/netinet/cc/`)

| Part | raw | code |
|---|---:|---:|
| framework: cc.c, cc.h, cc_module.h | 1061 | 590 |
| cc_newreno.c + .h | 661 | 415 |
| cc_cubic.c + .h | 1049 | 574 |
| others: dctcp 494/337, htcp 543/277, vegas 313/201, cdg 728/511, chd 509/319, hd 260/157 | 2847 | 1802 |
| **all cc** | **5618** | **3381** |

The CC hooks (`cc.h`, `struct cc_algo`) are: `cb_init, cb_destroy, conn_init,
ack_received, cong_signal, post_recovery, after_idle, ecnpkt_handler, newround,
rttsample, ctl_output, cc_data_sz`.

### RACK and BBR (`sys/netinet/tcp_stacks/` plus shared files, `tcp_hpts.c` and `.h` among them in `sys/netinet/`)

| Part | raw | code |
|---|---:|---:|
| rack.c | 24673 | 17726 |
| tcp_rack.h | 764 | 556 |
| rack_pcm.c | 334 | 234 |
| bbr.c | 14824 | 10538 |
| tcp_bbr.h | 817 | 554 |
| rack_bbr_common.c/.h (shared) | 1102 | 713 |
| sack_filter.c/.h (shared) | 1051 | 650 |
| tailq_hash.c/.h (RACK only) | 439 | 355 |
| tcp_hpts.c/.h (pacer, shared; in `sys/netinet/`, not `tcp_stacks/`, *(corrected)*) | 2328 | 1476 |
| tcp_lro_hpts.c (optional) | 673 | 510 |
| tcp_ratelimit.c (hardware pacing, optional) | 1795 | 1285 |
| **RACK total without hpts** | **28363** | **20234** |
| **RACK total with hpts** | **30691** | **21710** |
| **BBR total without hpts** | **17794** | **12455** |
| **BBR total with hpts** | **20122** | **13931** |

### IPv4 / UDP / IPv6 layers

| Group | raw | code |
|---|---:|---:|
| IPv4 core: ip_input 1408, ip_output 1590, ip_icmp 1204, ip_reass 984, ip_options 760, ip_id 298, ip_ecn 192, udp_usrreq 1819, if_ether 1529, in_pcb 3423, in.c 1897, in_cksum 253, raw_ip 1109 | 16466 | 11588 |
| IPv6 core: ip6_input 1763, ip6_output 3344, nd6 2737, nd6_nbr 1633, nd6_rtr 2619, icmp6 2907, udp6_usrreq 1315, frag6 1112, in6_src 1139, in6_pcb 1301, in6.c 2785, in6_ifattach 959, scope6 623, ip6_id 271, dest6 133, route6 116, raw_ip6 876 | 25633 | 17185 |
| left out (IGMP, MLD, multicast code and routing, fastfwd, forward, carp, divert, encap, gre, gif) | 25107 | 17048 |
| left out: SCTP (sctp_*.c + sctp6_usrreq.c) | 54341 | 43178 |

Whole-directory context: my IPv4, IPv6 and multicast file list totals 57963 raw
lines; the files above are not all of it (for example `in_fib*`, `ip_fw*`, `libalias`,
`netdump` are unlisted).

**Totals for a first version**: default TCP stack with ECN, host cache, TFO and
headers about 26 000 raw / 18 000 code lines; CUBIC and NewReno with the framework about
2 300 raw / 1 400 code; IPv4 plus IPv6 plus UDP core about 42 000 raw / 29 000 code.
Each is an upper bound on what must be read, not on what is written: most of the volume
is locking, mbuf handling, sysctls, logging, jail/vnet hooks and kernel-specific plumbing.

## 3. How much RACK and BBR share, and what RACK needs beyond the default stack

* **They share infrastructure, not the protocol engine.**
  `rack_bbr_common.c` (959 lines) holds `ctf_*` helpers copied out of the default
  stack's input path: `ctf_drop_checks` (trim and window checks), `ctf_process_rst`,
  `ctf_challenge_ack`, `ctf_ts_check`, `ctf_ack_war_checks`, `ctf_calc_rwin`,
  `ctf_do_dropwithreset`, `ctf_do_dropafterack`, plus `ctf_process_inbound_raw`
  (the HPTS/LRO queued-input path). `sack_filter.c` (a SACK block de-duplicating
  filter) is common to both. Beyond those ~2 100 lines, rack.c and bbr.c share
  nothing: each has its own output routine, ACK processing, timers, and a full set of
  per-state input handlers (`rack_do_close_wait` at `rack.c:525` and 24 more, 12 for
  BBR; they re-implement `tcp_do_segment`'s state switch).
* **RACK depends on, beyond the default stack:**
  1. HPTS, the high-precision timer system (`tcp_hpts.c`, 16 call sites in rack.c):
     every timer (RACK reordering, TLP, RTO, pacing gap, delayed ACK) is a HPTS
     timeout and output is driven from HPTS, not from the timer callouts of
     `tcp_timer.c`. RACK registers `tfb_tcp_rexmit_tmr` and friends.
  2. `tailq_hash.c`: a hash of sent-segment records (one per sent range, with send
     time, flags, retransmit count) which is the RACK scoreboard (96 uses in rack.c);
     the default stack uses RFC 6675 `sackhole` lists instead.
  3. `sack_filter.c`, `rack_pcm.c` (path capacity measurement), `tcp_ratelimit.c`
     (hardware pacing, optional, 3 uses), `tcp_log_buf.c` (BlackBox logging, 129
     call sites; compiled out by dropping it), `tcp_lro_hpts.c` (queued input),
     optional KTLS and sendfile deferred-send blocks (5 uses), hhook, and the
     function-block's `tfb_compute_pipe`, `tfb_early_wake_check`,
     `tfb_chg_query`, `tfb_inherit` hooks.
  4. The cc framework: `rack.c` calls the same `cc_algo` hooks (71 `cc_` references),
     so CUBIC and NewReno plug in unchanged; RACK adds its own pacing-rate logic on top.
* **What RACK is**: loss detection by sent-time (RFC 8985 RACK-TLP) plus a pacer
  plus its own timers. The default stack's loss detection is duplicate ACKs, RFC 6675
  SACK recovery, NewReno partial ACKs, PRR (RFC 6937) and a lost-retransmission check
  (`tcp_sack_lost_retransmission`, `tcp_sack.c:1156`).
* **BBR is a congestion-control algorithm shipped as a whole stack**, with its own
  `tcp_bbr.h` state model and pacing driven by HPTS. Its code (12 000 code lines)
  duplicates nearly everything RACK does for input and timers.

## 4. Proposed mapping to Erlang

Shape: pure state machines (functional core) that take an event and return the next
state plus a list of actions; a connection process (one per connection) that owns the
state and performs the effects (send packet, set or cancel timer, notify the socket
owner); behaviours for loss detection and congestion control that mirror
`struct tcp_function_block` and `struct cc_algo`.

Size classes: S under 400 Erlang lines, M 400-1500, L 1500-4000. These are guesses
from FreeBSD code lines minus what is dropped, at roughly 0.5 to 0.8 Erlang lines per
FreeBSD code line for logic and 0.2 for plumbing-heavy files.

All modules drop: mbufs (packets are binaries or decoded records), inpcb locks and
reference counts, vnet (`V_`/`VNET_`) indirection, sysctl and `SYSCTL_*` registration
(tunables become application-environment or per-socket options), kernel-debug
logging, jail and MAC hooks, DTrace/SDT probes, and the BlackBox log.

| Erlang module | Derived from | Drops, adds | Size |
|---|---|---|---|
| `erx_tcp_wire` | `tcp_dooptions` (`tcp_input.c:3501`), `tcp_addoptions` (`tcp_output.c:1794`), `tcp.h`, `tcpip.h`, pseudo-header checksum in `in_cksum.c`/`in6_cksum.c` | Segment encode and decode, option parser. Pure, bounds-checked with binary matching. Checksum goes to a per-byte C primitive. Fuzz target. | M |
| `erx_tcp_seq` | `tcp_seq.h` | SEQ_LT etc. as wrap-safe functions. | S |
| `erx_tcp_fsm` | `tcp_fsm.h`, state switch of `tcp_do_segment` (`tcp_input.c:1511-3500`), `tcp_twstart/twcheck` (`tcp_timewait.c`) | The core: `step(State, Event) -> {State, Actions}`. RFC 793 states, RFC 5961 challenge ACKs and in-window RST and SYN checks (`tcp_input.c:2167,2204`, `tcp_send_challenge_ack`, `tcp_subr.c:2213`), PAWS/timestamp checks, urgent data, FIN processing. No socket or mbuf code. Time-wait is a state, as in 15. | L |
| `erx_tcp_conn` | `tcp_usrreq.c`, `tcp_subr.c` (`tcp_newtcpcb:2233`, `tcp_close:2532`, `tcp_drop:2393`, `tcp_respond:1734`), socket-buffer interaction | gen_statem process, one per connection. Applies actions from `erx_tcp_fsm`, owns timers (`erlang:start_timer`), send and receive buffers, user API calls (connect, send, recv, close, shutdown, options). Drops inpcb. | L |
| `erx_tcp_output` | `tcp_default_output` (`tcp_output.c:186`, 1,355 code lines), `tcp_setpersist` | Pure `next_segment(State) -> {send, Seg, State} | idle`. Decides what and when to send: Nagle, silly-window avoidance (sender and receiver), window update, persist, TSO dropped (no segmentation offload at first), zero-window probes. | M |
| `erx_tcp_rtt` | `tcp_xmit_timer` (`tcp_input.c:3642`), RTO backoff in `tcp_timer.c` (`TCPT_RANGESET`) | RFC 6298 estimator with timestamps. Pure. | S |
| `erx_tcp_timers` | `tcp_timer.c` (rexmt `:554`, persist `:486`, keep `:380`, 2msl `:331`, delack `:309`) | Pure functions that say what a timer expiry does, including keepalive probe counts, the blackhole PMTUD fallback (`tcp_pmtud_blackhole_*`, `tcp_timer.c:170`; off by default, *(corrected)*), max retransmit. The callout and `tcp_timer_enter` machinery is dropped; Erlang timers replace it. | M |
| `erx_tcp_sack` | `tcp_sack.c` (`tcp_update_sack_list:289` receiver side, `tcp_sack_doack:576`, `tcp_sack_output:1061`, `tcp_sack_adjust:1111`, `tcp_sack_partialack:971`, lost retransmission `:1156`) | RFC 2018 and RFC 6675 scoreboard as an ordered structure (gb_trees or ordered list) instead of the linked hole list; keep the reneging and lost-retransmission logic. Pure. | M |
| `erx_tcp_reass` | `tcp_reass.c` (`tcp_reass:516`, merge helpers) | Out-of-order queue as an ordered map keyed by sequence; keep the overlap trimming and memory cap. Drops mbuf-chain accounting (`tcp_reass_overhead_of_chain`). | S |
| `erx_tcp_loss` (behaviour) | `tfb_tcp_do_segment` loss part, `cc_cong_signal` callers, `tcp_do_prr_ack:4026`, `tcp_newreno_partial_ack:4114`; later RACK | Behaviour with callbacks `on_ack/3`, `on_timeout/2`, `on_sack/3`, `next_timer/1`. Default implementation `erx_tcp_loss_dupack` (3 dupacks, RFC 6675, NewReno partial ack, PRR, RFC 3042 limited transmit). A later `erx_tcp_loss_rack` implements RFC 8985. Mirrors the function-block seam without per-state duplication. | M (default), M later (RACK) |
| `erx_tcp_cc` (behaviour) | `cc/cc.h` `struct cc_algo`; the hook callers `cc_ack_received`, `cc_conn_init` and `cc_cong_signal`, which are in `tcp_input.c` at `:290`, `:361` and `:416`, not in `cc/cc.c` *(corrected)*; `cc_newreno.c`, `cc_cubic.c` | Callbacks: `init/1, ack_received/3, cong_signal/3, post_recovery/2, after_idle/2, ecn_pkt/2, rtt_sample/3, newround/2`. Modules `erx_tcp_cc_newreno` (S) and `erx_tcp_cc_cubic` (S-M). Cubic's fixed-point math becomes integer Erlang. Drops `cc_data_sz`, module load registry, hhook ertt coupling. | S + S + M |
| `erx_tcp_mss` | `tcp_mss`, `tcp_mss_update` (`tcp_input.c:3742,3899`), `tcp_mtudisc` (`tcp_subr.c:3594`), `tcp_ctlinput_with_port` (`tcp_subr.c:3091`), `tcp_compute_initwnd` (`tcp_input.c:4167`, *(corrected)*) | MSS negotiation, PMTUD reaction to ICMP, initial window (RFC 6928 style). Pure. | S |
| `erx_tcp_syncache` | `tcp_syncache.c` (`syncache_add:1363`, `syncache_expand:1040`, `syncache_respond:1799`, `syncache_chkrst:615`, cookies `syncookie_mac:2194`, declared at `:132` *(corrected)*) | Listener-side half-open state. Keep: bounded table, retransmit timer with backoff, cookies (*corrected:* while syncookies are on, every SYN-ACK's initial sequence number is a cookie, `tcp_syncache.c:1726-1729`, not only when the table is full; an ACK that matches no entry is checked as a cookie only within 15 s of its bucket's last overflow, `:1095`; and a completed handshake that finds the listen queue full is answered with a RST by default, `tcp_sc_rst_sock_fail`, `:215`), RST and ICMP unreach handling, SYN-flood policy. The MAC is a keyed hash from crypto (SipHash in FreeBSD, `tcp_syncache.c:59`; we can use HMAC or `crypto:mac(poly1305/siphash)`). Drops buckets, per-bucket mutex, `syncache_pause`. | M |
| `erx_tcp_isn` | `tcp_new_isn` (`tcp_subr.c:3521`) | RFC 6528: keyed hash of the four-tuple plus a clock plus random increment; the secret is never reseeded by default, `tcp_isn_reseed_interval` 0 at `tcp_subr.c:286` *(corrected)*. Pure given secret and time. | S |
| `erx_tcp_ecn` | `tcp_ecn.c` (all functions listed in section 2) | RFC 3168 and AccECN (15 has both in this one file); pure state updates on input and output. Lower priority; can start with RFC 3168 only. | S-M |
| `erx_tcp_hostcache` | `tcp_hostcache.c` | Per-destination cache of MTU, RTT, ssthresh, cwnd; aged. ETS table in a manager process. Optional first version (MTU part is needed for PMTUD). | S |
| `erx_tcp_fastopen` | `tcp_fastopen.c` | Cookie generation and checking. Defer. | M, later |
| `erx_tcp_demux` | `in_pcb.c` lookup (`in_pcblookup_*`) plus `tcp_input_with_port` (`tcp_input.c:594`) | Four-tuple to connection pid via a registry (ETS) plus listener table and port allocation (`in_pcbbind`, ephemeral selection; FreeBSD randomises ephemeral ports, `in_pcb.c`; the `SO_REUSEPORT` rule that sharers have the same user is in `in_pcbbind_avail`, `in_pcb.c:912` *(corrected)*). Drops lock-free hashing, groups, RSS, load balancing. | M |
| `erx_udp` | `udp_usrreq.c` (+ `udp6_usrreq.c`) | Datagram demux, checksum, ICMP error delivery, socket options; drops encapsulation, multicast, UDP-Lite, `udp_tun_func`. | M |
| `erx_ip4` | `ip_input.c`, `ip_output.c`, `ip_options.c`, `ip_id.c`, `ip_ecn.c`, `in_cksum.c` | Pure header validation (version, IHL, length, checksum, bogus address checks), protocol dispatch, output (route lookup is an effect, DF and fragmentation, TTL, TOS, ID randomisation). Drops firewall hooks, forwarding, `ipfw`, mbuf tags, packet filter. | M |
| `erx_ip4_reass` | `ip_reass.c` | Fragment reassembly with caps and timeout (security-relevant; fuzz target). Pure state plus one timer. | S-M |
| `erx_icmp4` | `ip_icmp.c` | Echo reply, unreachable and frag-needed delivery to TCP/UDP, rate limit (`icmplim`) kept, redirects handled or refused. | S-M |
| `erx_arp` | `if_ether.c` | ARP cache state machine (incomplete, reachable, stale, probe), request queue of waiting packets, timers; gratuitous ARP and duplicate-address detection. | M |
| `erx_ip6` | `ip6_input.c`, `ip6_output.c`, `dest6.c`, `route6.c`, `ip6_id.c`, `scope6.c`, `in6_src.c` | Header and extension-header parse (hop-by-hop, destination, routing type 2 only, fragment), source-address selection (RFC 6724) and scope zones, output. Routing header type 0 refused. | L |
| `erx_ip6_reass` | `frag6.c` | IPv6 fragment reassembly with the RFC 8200 and RFC 5722 overlap rule. Fuzz target. | S-M |
| `erx_icmp6` | `icmp6.c` | Echo, errors, PMTU (packet-too-big), rate limits; drops MLD, NI queries, router renumbering. | M |
| `erx_nd6` | `nd6.c`, `nd6_nbr.c`, `nd6_rtr.c`, `in6_ifattach.c` | Neighbour cache state machine (RFC 4861), DAD, SLAAC (RFC 4862), router solicitation and RA processing, default-router list, prefix list, stable-privacy addresses (RFC 7217). Biggest IPv6 piece. Drops SEND (`send.c`), MLD interplay. | L |
| `erx_in_addr` | `in.c`, `in6.c`, `in_var.h` | Interface address lists, subnet and broadcast tests, address lifetimes. | M |
| `erx_raw` | `raw_ip.c`, `raw_ip6.c` | Raw sockets for ping. Optional. | S |

Seams that need a decision by the design writer (not settled by FreeBSD):

* Where the RACK-style scoreboard and the RFC 6675 scoreboard meet: one send-record
  structure serving both is the one thing that would make `erx_tcp_loss` a true
  behaviour rather than two code paths. FreeBSD never unified them (that is why RACK
  is a second stack).
* Timers: in FreeBSD all connection timers are callouts under the inpcb lock; here
  they are messages to the connection process, so a late timer message carries a
  generation number or reference and is ignored if stale.
* Layering: the IP layer is a separate process or set of processes, so TCP
  connection processes receive already-validated segments and send through a funnel.

## 5. What FreeBSD offers as a test oracle

* **No packetdrill in the src tree.** `tests/sys/netinet` holds ATF tests, not
  packetdrill scripts: `ip_reass_test.c`, `tcp_connect_port_test.c`,
  `tcp_implied_connect.c`, `tcp_md5_getsockopt.c`, `tcp_user_cookie.c`,
  `udp_bindings.c`, `udp_io.c`, `udp_dontroute.c`, `socket_afinet.c`,
  `so_reuseport_lb_test.c`, `ip6_v4mapped_test.c`, `broadcast.c`, plus shell, scapy
  (`.py`) tests for forwarding, redirect, multicast, carp, arp, fibs. `tests/sys/netinet6`
  has `frag6/` (about 40 scapy tests of IPv6 fragment handling), `exthdr`, `mld`,
  `ndp.sh`, `ra.py`, `redirect.py`, `test_ip6_output.py`. `contrib/netbsd-tests/net`
  has more socket-level ATF tests. All ATF tests are BSD-licensed like the kernel
  (SPDX tags BSD-2/BSD-3) but they test sockets of a running FreeBSD, so we can only
  read them for expected behaviour, or run them against our socket layer when it
  exists.
* **FreeBSD tcp-testsuite** (github.com/freebsd-net/tcp-testsuite, default branch
  `master`, last push 2026-05-03): BSD-3-Clause style licence text (LICENSE.md,
  "Copyright (c) 2016, Michael Tuexen", no SPDX tag), about
  1103 `.pkt` scripts: state-event-engine 885 files (every segment type in every TCP
  state), rcv-data-segments 219 (overlapping segments in many offsets), fast-open 156,
  tcp-over-udp 60, snippets 39, snd-syn 34, socket-api 32, rcv-icmp 15. It has both
  IPv4 and IPv6 variants (about 389 and 382 files). It contains very little for SACK,
  congestion control or RACK (4 file names mention SACK); it checks the state machine,
  not loss recovery. The packetdrill version it needs is nplab's, not Google's:
  `github.com/nplab/packetdrill` (README says so); `github.com/freebsd-net/packetdrill`
  is a fork "with UDPLite and SCTP support and bug fixes for FreeBSD" with licence
  field GPL-2.0 (GitHub API; `google/packetdrill` is GPL-2.0 too). The packetdrill tool is a GPL-2.0 test
  tool: fine as an out-of-tree oracle fetched at a pinned version (per erXos
  CLAUDE.md "tools and test oracles stay out of the tree"), never linked.
* **Fit for erXos**: packetdrill drives a stack through a TUN device or, with a
  small adapter, through a script of packets; the erXos stack can expose its link
  input and output as a packet pipe so packetdrill can run on the host against
  hosted mode. That is a design choice for the test plan, not something in FreeBSD.
  For loss recovery, Google's own packetdrill TCP scripts (the Linux gtests) are the
  better source, not in the FreeBSD tree.
* Not checked: Linux packetdrill test licence for those scripts (Apache-2.0 and GPL
  mix in `google/packetdrill`); verify before using any.

## 6. Features: leave out first, and features to keep

**Leave out of the first version**

* IPsec and TCP-MD5 signature (`tcp_md5` in `tcp_input.c:1357-1364`, `tcpmd5` module),
  TCP-AO is not in this tree.
* Multicast: IGMP, MLD, `in_mcast.c`, `ip_mroute.c`, `ip6_mroute.c`, PIM
  (25 000 raw lines together with forwarding and tunnel code; IPv6 ND needs only the
  solicited-node group join, which can be a narrow special case).
* SCTP (54 000 raw lines), DCCP, UDP-Lite.
* TOE (`tcp_offload.c`), KTLS, sendfile deferred blocks, hardware rate limiting
  (`tcp_ratelimit.c`), LRO (`tcp_lro*.c`), TSO and checksum offload bookkeeping.
* BlackBox logging (`tcp_log_buf.c`, 3352 lines), `tcp_stats.c`, hhook, DTrace probes,
  `tcp_accounting.h`, `tcp_pcap`, netdump.
* Packet filters and NAT (`ipfw`, `libalias`, pf), divert, carp, gre, gif, `ip_encap`,
  ipv4 forwarding and fastfwd, IPv6 forwarding, mroute.
* Alternative stacks and cc modules: RACK, BBR, HPTS, CDG, CHD, HD, H-TCP, Vegas,
  DCTCP (DCTCP is small and needs only the ECN hook; add later if wanted).
* Stack switching at run time (`tcp_function_block` registry, per-socket
  `TCP_FUNCTION_BLK`): keep the seam, drop the registry and aliasing code
  (`tcp_subr.c:392-740`).
* SEND (secure ND), router renumbering, ICMPv6 node information queries, anycast.
* Hostcache, TFO: optional, second wave.

**Features the default stack has that we must keep**

| Feature | FreeBSD evidence | Note |
|---|---|---|
| Syncache and SYN cookies | `tcp_syncache.c`, `tcp_syncookies = true` at `tcp_syncache.c:105`, `syncookies_only` at `:111` | Listener must survive SYN floods without a process per half-open connection. Every SYN-ACK carries a cookie while cookies are on (`:1726-1729`) *(corrected)*. |
| RFC 5961 (blind-attack mitigations) | `tcp_insecure_rst = 0`, `tcp_insecure_syn = 0` (`tcp_input.c:197-204`), checks at `:2167`, `:2204`, challenge ACK `tcp_subr.c:2213` | On by default in FreeBSD; make it unconditional. |
| RFC 6528 ISN | `tcp_new_isn`, `tcp_subr.c:3521` (keyed SipHash of the four-tuple, random increment; secret not reseeded by default, `tcp_subr.c:286` *(corrected)*) | |
| SACK (RFC 2018, 6675), PRR (RFC 6937) | `tcp_sack.c`, `tcp_do_prr = 1` (`tcp_input.c:162`) | |
| Limited transmit, IW10 | `tcp_do_rfc3042 = 1`, `tcp_do_rfc3390 = 1` (`tcp_input.c:172,177`), `tcp_compute_initwnd` | |
| Window scaling, timestamps (RFC 7323) | `tcp_do_rfc1323 = 1` (`tcp_subr.c:207`) | Timestamps also give PAWS and RTT samples. |
| ECN (RFC 3168, AccECN) | `tcp_ecn.c` | Off or passive on outbound by default; keep. |
| PMTUD | `tcp_mtudisc` (`tcp_subr.c:3594`), `tcp_ctlinput_with_port` (`:3091`), blackhole detection (`tcp_timer.c:170-177`), off by default *(corrected)* | Also needs the ICMP and ICMPv6 side. |
| Keepalive and persist timers | `tcp_timer_keep:380`, `tcp_timer_persist:486` | |
| Autosizing buffers | `tcp_do_autosndbuf = 1` (`tcp_output.c:116`) and the receive-side counterpart | Needs the socket buffer API; design decision. |
| Time-wait and 2MSL | `tcp_timewait.c` | Keep the RFC 1337 and assassination guards. |
| Out-of-order reassembly with caps | `tcp_reass.c` | Memory limits are a security matter. |
| IP and IPv6 fragment reassembly with caps | `ip_reass.c`, `frag6.c` | |
| ND6, DAD, SLAAC | `nd6*.c` | |
| ICMP rate limiting | `ip_icmp.c`, `icmp6.c` | |
| CC: NewReno, CUBIC | `cc/cc_newreno.c`, `cc/cc_cubic.c`; CUBIC is the default (`cc.c:83`) | |

## 7. Licences

Counts are the SPDX identifiers found in the file headers, by the scratch
script named above. Files with no SPDX tag were read for licence text.

| Family | Licence found | Verdict |
|---|---|---|
| `tcp_input.c`, `tcp_output.c`, `tcp_timer.c`, `tcp_subr.c`, `tcp_sack.c`, `tcp_usrreq.c`, `tcp_reass.c`, `tcp_timewait.c`, `tcp_seq.h`, `tcp_fsm.h`, `tcp_timer.h`, `tcp_var.h`, `tcp.h`, `tcp_ecn.c`, `tcp_hostcache.c` | BSD-3-Clause | translate |
| `tcp_syncache.c`, `tcp_syncache.h` (.h is BSD-3-Clause) | BSD-2-Clause | translate |
| `cc/cc.c`, `cc_newreno.c`, `cc_cubic.c`, `cc_vegas.c` and the others | BSD-2-Clause (cc_dctcp.c, cc.h, cc_newreno.h have BSD text without an SPDX line) | translate |
| `tcp_fastopen.c` | BSD-2 text, no SPDX tag (Patrick Kelsey) | translate later |
| `ip_input.c`, `ip_output.c`, `ip_icmp.c`, `ip_options.c`, `ip_ecn.c`, `in_pcb.c`, `in.c`, `if_ether.c`, `raw_ip.c`, `udp_usrreq.c`, `in_proto.c` | BSD-3-Clause | translate |
| `ip_reass.c`, `ip_id.c` | BSD text without SPDX (`ip_reass.c`) and BSD-2-Clause (`ip_id.c`) | translate |
| netinet6: `ip6_input.c`, `ip6_output.c`, `nd6*.c`, `icmp6.c`, `frag6.c`, `in6*.c`, `scope6.c`, `udp6_usrreq.c`, `dest6.c`, `route6.c`, `raw_ip6.c`, `in6_src.c` | BSD-3-Clause (KAME code, BSD-3 with the KAME copyright) | translate |
| `ip6_id.c` | `BSD-3-Clause AND BSD-2-Clause` (two authors) | fine, but list both |
| `tcp_stacks/rack.c`, `bbr.c`, `rack_bbr_common.*`, `rack_pcm.c`, `sack_filter.*`, `tcp_rack.h`, `tcp_bbr.h`, `tcp_hpts.*`, `tcp_lro_hpts.c` | Netflix BSD-2 text, no SPDX tag | not proposed for first version; licence is fine |
| **`tcp_stacks/tailq_hash.c`, `tailq_hash.h`** | **no licence header at all** (Netflix; first lines are `#include`) | **avoid copying; if RACK is ever done, re-derive from the idea or ask the file's authors** |
| **`netinet/in_cksum.c`** | **BSD-4-Clause** (original advertising clause at `in_cksum.c:17`) | **do not translate; the Internet checksum is a few lines to write fresh, and we planned it as a C primitive** |
| `tcp_accounting.h`, `in_rmx.c`, `ip_carp_nl.h`, `icmp6.h`, `ip6.h` | no SPDX found; `netinet6/ip6.h` and `icmp6.h` are stub headers that say "obsolete, use netinet/ip6.h" | not needed |
| `tests/sys/netinet*` ATF tests | BSD-2/BSD-3 | read only |
| tcp-testsuite scripts | BSD-3-Clause text (LICENSE.md) | usable as oracle |
| packetdrill (nplab, freebsd-net fork, google) | GPL-2.0 per GitHub API | tool only, fetched out of tree, never linked |

No file in the proposed translation set is GPL, LGPL or has a non-BSD licence apart
from `in_cksum.c` (BSD-4-Clause) and the header-less `tailq_hash.c`. Many BSD-3 files carry
Berkeley and other copyright holders: a translation is a derived work, so the
erXos tree must keep each file's copyright notice and licence text in the translated
module's header, as CLAUDE.md already requires for imported code. The BSD-licensed
translation does not conflict with erXos's own licence choices, but the design writer
should check how the project wants to record "translated from" notices.

## Recommendation

Use the **default ("freebsd") stack as the main reference** for the first version.

1. It is the stack FreeBSD ships and tests by default, and the tcp-testsuite checks it.
2. It is about 14 000 code lines with a small, clear cc seam, against RACK's 21 700
   (with HPTS) and BBR's 13 900.
3. RACK is a second TCP implementation that duplicates the state machine and depends on
   HPTS, the sent-segment hash and BlackBox logging; translating it first would mean
   translating HPTS and a second input path before the system sends a byte.
4. Keep the `erx_tcp_loss` seam so a RACK-TLP module (RFC 8985) can be added later,
   reading RACK's `rack.c` for the logic of TLP and the reorder window, and designing the
   send-record structure with RACK in mind (see the seam note in section 4).

Cautions for the writer: in the default stack, rack_bbr_common's `ctf_*` helpers are a
useful small catalogue of the input-path checks in a form that is already separated
from the big function; `tcp_do_segment` is 2000 lines that mix state handling, ACK
processing and data delivery, and should be split by event rather than ported in order.
