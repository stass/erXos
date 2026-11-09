%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% An ICMPv4 message (RFC 792) as erx_icmp4_wire decodes and encodes it: its type, code and
%% the fields of its kind (erx_icmp4_wire:msg()). The checksum is not kept: a decoded message
%% has had it checked, and encoding computes it. The type names are FreeBSD's, from
%% netinet/ip_icmp.h.
-record(icmp4, {type :: 0..255, code :: 0..255, msg :: erx_icmp4_wire:msg()}).

-define(ICMP_ECHOREPLY, 0).
-define(ICMP_UNREACH, 3).
-define(ICMP_REDIRECT, 5).
-define(ICMP_ECHO, 8).
-define(ICMP_TIMXCEED, 11).
-define(ICMP_PARAMPROB, 12).
-define(ICMP_TSTAMP, 13).
