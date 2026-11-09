%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% An Ethernet II header as erx_net_eth decodes and encodes it: the destination and source
%% addresses as their six wire bytes and the EtherType as an integer. Any EtherType decodes;
%% the stack's classifier acts on those named below and drops the rest.
-record(eth, {dst :: <<_:48>>, src :: <<_:48>>, type :: 0..16#FFFF}).

%% EtherTypes (net/ethernet.h).
-define(ETHERTYPE_IP, 16#0800).
-define(ETHERTYPE_ARP, 16#0806).
-define(ETHERTYPE_IPV6, 16#86DD).
