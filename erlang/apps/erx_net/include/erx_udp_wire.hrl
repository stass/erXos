%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A UDP header (RFC 768) as erx_udp_wire decodes and encodes it, over IPv4 or IPv6. The
%% length is not kept: it is 8 bytes plus the payload's. The checksum is not kept either:
%% `csum` is `checked` for a datagram whose checksum the decoder checked, and `absent` for one
%% that carries none (a zero checksum field), which only IPv4 allows; erx_udp refuses it over
%% IPv6 (RFC 8200, section 8.1). Encoding computes the checksum, or writes zero for `absent`.
-record(udp, {sport :: 0..16#ffff, dport :: 0..16#ffff, csum = checked :: checked | absent}).
