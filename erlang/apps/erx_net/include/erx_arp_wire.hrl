%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% An ARP packet for IPv4 over Ethernet as erx_arp_wire decodes and encodes it, RFC 826's
%% fields named as FreeBSD's struct arphdr names them. The protocol type and both address lengths are
%% fixed by the decoder's checks (IPv4, 6-byte hardware and 4-byte protocol addresses), so the
%% record keeps only the hardware type, which may be either Ethernet value, and the operation,
%% which any value may take; erx_arp acts on requests and replies.
-record(arp, {hrd :: 0..16#FFFF, op :: 0..16#FFFF,
              sha :: <<_:48>>, spa :: <<_:32>>, tha :: <<_:48>>, tpa :: <<_:32>>}).

%% Hardware types and operations (net/if_arp.h).
-define(ARPHRD_ETHER, 1).
-define(ARPHRD_IEEE802, 6).
-define(ARPOP_REQUEST, 1).
-define(ARPOP_REPLY, 2).
