%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A DHCP message (RFC 2131 section 2) as erx_dhcp4_wire decodes and encodes it. The
%% server host name and boot file fields are not kept: the client reads neither, and the
%% encoder writes them as zeros. `chaddr` holds the client hardware address's `hlen` bytes;
%% `options` holds the options erx_dhcp4_wire knows, each checked (erx_dhcp4_wire:options()).
-record(dhcp4, {op = request :: request | reply,
                htype = 1 :: 0..255,
                hops = 0 :: 0..255,
                xid :: 0..16#ffffffff,
                secs = 0 :: 0..16#ffff,
                broadcast = false :: boolean(),
                ciaddr = <<0:32>> :: <<_:32>>,
                yiaddr = <<0:32>> :: <<_:32>>,
                siaddr = <<0:32>> :: <<_:32>>,
                giaddr = <<0:32>> :: <<_:32>>,
                chaddr :: binary(),
                options = #{} :: erx_dhcp4_wire:options()}).
