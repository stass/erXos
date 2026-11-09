%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% An IPv4 header as erx_ip4_wire decodes and encodes it, RFC 791's fields named as
%% FreeBSD's struct ip names them. The
%% header length is not kept: it is 20 bytes plus the options, which stay as their wire bytes
%% (a multiple of four, at most 40) so that encoding gives back the header received;
%% erx_ip4_wire:options/1 lists them. The header checksum is not kept either: a decoded header
%% has had it checked, and encoding computes it. `rf`, `df` and `mf` are the three flag bits
%% (reserved, don't fragment, more fragments), and `off` the fragment offset in 8-byte units.
-record(ip4, {tos = 0 :: 0..255, len :: 0..16#FFFF, id = 0 :: 0..16#FFFF,
              rf = 0 :: 0..1, df = 0 :: 0..1, mf = 0 :: 0..1, off = 0 :: 0..16#1FFF,
              ttl :: 0..255, p :: 0..255, src :: <<_:32>>, dst :: <<_:32>>,
              options = <<>> :: binary()}).

%% Option types (netinet/ip.h).
-define(IPOPT_EOL, 0).
-define(IPOPT_NOP, 1).
-define(IPOPT_RR, 7).
-define(IPOPT_TS, 68).
-define(IPOPT_LSRR, 131).
-define(IPOPT_SSRR, 137).
