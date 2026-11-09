%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A TCP header (RFC 9293) as erx_tcp_wire decodes and encodes it. Sequence and
%% acknowledgement numbers, timestamps and SACK edges are the 32-bit values on the wire;
%% erx_tcp_seq:lift/2 turns them into the connection's unwrapped integers. The data offset is
%% not kept, since it follows from the options, nor the checksum: a decoded segment has had
%% it checked, and encoding computes it.

%% The flag bits of `flags`, FreeBSD's `thflags` (tcp.h, tcp_get_flags): the eight flags of
%% the header's fourteenth byte, and above them the four bits before it, of which the lowest
%% is AccECN's AE.
-define(TH_FIN, 16#01).
-define(TH_SYN, 16#02).
-define(TH_RST, 16#04).
-define(TH_PUSH, 16#08).
-define(TH_ACK, 16#10).
-define(TH_URG, 16#20).
-define(TH_ECE, 16#40).
-define(TH_CWR, 16#80).
-define(TH_AE, 16#100).

%% The options a segment carried that the stack acts on (FreeBSD's `struct tcpopt`), each
%% absent unless the segment carried it well formed. MSS, window scale and SACK-permitted
%% count only on a SYN, SACK blocks only on a segment without SYN, as `tcp_dooptions` reads
%% them; a window scale above 14 reads as 14. `signature` says the segment carried a TCP-MD5
%% option (RFC 2385, FreeBSD's TOF_SIGNATURE); the stack signs nothing, so the syncache
%% refuses such a segment as FreeBSD's refuses it for a listener without TCP-MD5, and the
%% encoder writes no such option.
-record(tcp_opts, {mss = none :: none | 0..16#ffff,
                   wscale = none :: none | 0..14,
                   sack_permitted = false :: boolean(),
                   ts = none :: none | {TsVal :: erx_tcp_seq:wire(), TsEcr :: erx_tcp_seq:wire()},
                   sacks = [] :: [{Start :: erx_tcp_seq:wire(), End :: erx_tcp_seq:wire()}],
                   signature = false :: boolean()}).

-record(tcp, {sport :: 0..16#ffff,
              dport :: 0..16#ffff,
              seq :: erx_tcp_seq:wire(),
              ack :: erx_tcp_seq:wire(),
              flags :: 0..16#fff,
              win :: 0..16#ffff,
              urp :: 0..16#ffff,
              opts = #tcp_opts{} :: #tcp_opts{}}).
