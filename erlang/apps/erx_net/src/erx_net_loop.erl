%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_loop).
-moduledoc """
The loopback transport (docs/design-network-stack.md, "Loopback", "The driver"): each
packet it is given to transmit comes back to its own interface as a received frame, as
FreeBSD's `looutput` hands the packet to `if_simloop`, which queues it for input
(`if_loop.c:196-264`, `:278-357`).

A frame of the loopback interface is an IP packet with no link header but its zone, the
name of the interface that owns the packet's destination, which the sender's path gave it
(`erx_net_frame:link/3`). `transmit/2` sends the frame to the driver's own mailbox as
`{erx_net_loop, Ref, Zone, Packet}`, with a reference made at `init`, and `event/2` hands
such a message back up as a batch of one, `{Zone, Packet}`; a message with another
reference, which no other process can make, is no frame and is ignored. The queue
between them is the driver's mailbox, bounded by the interface's transmit credit, as
FreeBSD's is the netisr queue.

The link: `none`, no link-layer address, an MTU of 16,384 (FreeBSD's `LOMTU`,
`if_loop.c:81`), always `up`. The loop finishes no checksum (`finish` `none`): the frame
layer hands it finished packets and cut runs, since nothing below the loopback finishes or
cuts. A frame that is not `{Zone, Packet}` is dropped as `malformed`, and a packet longer
than the MTU as `too_long`; both are type and size checks, not a parse.

The configuration: `tx_limit`, the frames that may wait at the driver (256 when absent).
""".

-behaviour(erx_net_driver).

-export([init/1, event/2, transmit/2]).

-define(LOMTU, 16384).
-define(TX_LIMIT_DEFAULT, 256).

-doc false.
init(Config) ->
    case maps:get(tx_limit, Config, ?TX_LIMIT_DEFAULT) of
        Limit when is_integer(Limit), Limit > 0 ->
            {ok, #{link => none, lladdr => none, mtu => ?LOMTU, state => up, tx_limit => Limit,
                   finish => none}, make_ref()};
        Limit ->
            {error, {tx_limit, Limit}}
    end.

-doc false.
event({erx_net_loop, Ref, Zone, Packet}, Ref) ->
    {[{frames, [{Zone, Packet}]}], Ref};
event(_Msg, Ref) ->
    {[], Ref}.

-doc false.
transmit({Zone, Packet}, Ref) when is_binary(Packet); is_list(Packet) ->
    case iolist_size(Packet) of
        Size when Size =< ?LOMTU ->
            self() ! {erx_net_loop, Ref, Zone, iolist_to_binary(Packet)},
            {ok, Ref};
        _ ->
            {{drop, too_long}, Ref}
    end;
transmit(_Frame, Ref) ->
    {{drop, malformed}, Ref}.
