%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A UDP header (RFC 768) as erx_udp_wire decodes and encodes it, over IPv4 or IPv6. The
%% length is not kept: it is 8 bytes plus the payload's. The checksum is not kept either: a
%% decoded datagram has had it checked (or, over IPv4, carried none), and encoding computes it.
-record(udp, {sport :: 0..16#ffff, dport :: 0..16#ffff}).
