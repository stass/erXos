%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_if_core).
-moduledoc """
The interface process's step (docs/design-network-stack.md, "The interface core"): a pure
value holding the sub-cores of one interface's state, Ethernet or the loopback, which dispatches each event
to the sub-core it belongs to and returns the actions for erx_net_if to perform in order.

It holds the interface's IPv4 configuration (static, or a DHCP lease that the interface's
erx_dhcp4 configures), the ARP table (erx_arp), the ICMP limiters (erx_net_bandlim), the
ingress bucket, the syncache (erx_tcp_syncache), its copy of the stack's configuration, its
generator and its counters. The paths it carries are ARP, ICMP echo, the DHCP client's
messages, UDP and TCP to a closed port, IPv4 TCP to a listener, and the RSTs connections
hand it; every other local item and event is counted as `unsupported`, until the cores of
IPv6 and reassembly join the step.

**Passive open.** A segment for a listener goes to the interface's syncache, as FreeBSD's
`tcp_input` hands a listen socket's segments to `syncache_add`, `syncache_expand` and
`syncache_chkrst` (sys/netinet/tcp_input.c:1069-1229), so a SYN flood reaches no other
process and creates none (docs/design-network-stack.md, "Connection setup"). The step's
context then carries the stack's secrets, which the loop reads for that segment alone. A
completed handshake becomes an `accept` action, carrying the listener's entry, the
four-tuple, the handshake, the completing segment and a generator split for the
connection; the loop starts the connection, or steps `accept_refused` when the listener
has no room, and the core answers that with a RST. The table's SYN-ACK retransmissions run
from `{expired, Now}` and its deadline joins `next_deadline/1`.

**RSTs.** Every RST the stack sends passes the interface's `tcp_rst` limit
(`badport_bandlim`): the answer to a segment for a closed port, which the core builds as
`tcp_dropwithreset` does without a connection (sys/netinet/tcp_input.c), and a
connection's `{reset, ...}`, framed by the connection and resolved here. `charge_rst`
counts one against the limit without sending anything.

**The ingress bucket.** A local frame, one that names no socket, spends a token of the
interface's bucket before it is verified, and gets it back when the check fails, all
inside one step ([Receiving](#receiving)). The bucket refills at `rate` frames per second
up to `burst`. An ARP reply from a neighbour the table is resolving is free, so address
resolution keeps working under a flood ("The ingress limiter").

**Time.** The step's context is the time in microseconds; erx_arp and the limiters keep
milliseconds and get it divided.

**Frames out.** The core frames what it sends itself. An ARP packet goes to the address
erx_arp names; a DHCP message before the lease is broadcast from 0.0.0.0 with the TTL of
`dhclient`'s own IP header (16, `sbin/dhclient/packet.c`); every other datagram, an echo
reply, a port unreachable error or a renewal, takes a path from the configuration copy and
goes through erx_arp's `resolve/5`, which sends it at once to a resolved neighbour or holds
it while it asks.
""".

-include("erx_arp_wire.hrl").
-include("erx_dhcp4_wire.hrl").
-include("erx_icmp4_wire.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_net_eth.hrl").
-include("erx_udp_wire.hrl").
-include("erx_tcp_wire.hrl").

-export([new/1, step/3, view/1, next_deadline/1]).

-export_type([core/0, config/0, context/0, event/0, action/0, rows/0, status/0]).

-define(PROTO_UDP, 17).
-define(DHCP_CLIENT_PORT, 68).
-define(DHCP_SERVER_PORT, 67).
-define(DHCP_TTL, 16).
-define(HLIM, 64).
-define(ANY, <<0:32>>).
-define(BROADCAST4, <<255, 255, 255, 255>>).
-define(ETHER_BROADCAST, <<16#ffffffffffff:48>>).
-define(TOKEN, 1000000).                 % one frame, in token-microseconds
-define(INGRESS_DEFAULT, #{rate => 1000, burst => 256}).

-doc """
How the interface is configured: `ip4` is `dhcp`, or a static address with its prefix
length and an optional default gateway; `ingress` the bucket's rate in frames per second
and its burst.
""".
-type config() :: #{ip4 := dhcp | #{addr := <<_:32>>, plen := 0..32, gateway => <<_:32>>},
                    ingress => #{rate := pos_integer(), burst := pos_integer()}}.

-type event() ::
      start                                           % the first step: publish, announce
    | {local, erx_net_input:pending()}               % classify/2 answered local
    | {reinject, erx_net_input:key(), [erx_tcp:segment()]}
    | {resolve | reset, NextHop :: term(), Src :: term(), [erx_net_frame:packet()]}
    | charge_rst
    | {hint, NextHop :: term()}
    | {config, Gen :: non_neg_integer(), erx_net_frame:snapshot()}
    | {link, up | down}
    | {dhcp, erx_dhcp4_core:action()}                % from the interface's erx_dhcp4
    | {ifid, Ref :: reference(), {ok, binary()} | unavailable}
    | {accept_refused, Conn :: term(), erx_tcp:segment()}
    | {admin, Request :: term(), From :: term()}     % netadmin's requests
    | {drop, Reason :: atom()}                       % the loop dropped a frame
    | {merged, Units :: pos_integer(), Segments :: pos_integer()} % a batch's units of the merge
    | {expired, Now :: integer()}.

-type action() ::
      {transmit, [erx_net_frame:frame()]}            % to its driver
    | {publish, rows()}                              % its rows of the configuration tables
    | {neigh, publish, Ip :: binary(), LinkAddr :: binary(), fresh | stale}
    | {neigh, unpublish, Ip :: binary()}
    | {dhcp, {reply, #dhcp4{}} | {link, up | down}}
    | {accept, erx_net_input:entry(), erx_tcp_syncache:conn(), erx_tcp_syncache:handshake(),
       erx_tcp:segment(), erx_net_rand:gen()}  % a completed handshake, for the listener
    | {reply, From :: term(), Reply :: term()}.

-doc """
What the `status` request answers, netadmin's view of the interface: its name, link-layer
address and MTU; the driver's latest link state; whether its IPv4 configuration is static
or from DHCP; its addresses in the order it added them and its routes; and the name
servers and search list of its lease, empty without one.
""".
-type status() :: #{name := term(), lladdr := <<_:48>> | none, mtu := pos_integer(),
                    link := up | down, config := static | dhcp,
                    addrs := [erx_net_addr:row()], routes := [erx_net_route:row()],
                    dns := [<<_:32>>], search := [binary()]}.

-doc """
The complete set of the interface's rows, without what only its process knows (its pid,
its credits and its driver's): its `erx_net_ifs` fields, its addresses in the order it
added them, and its routes.
""".
-type rows() :: #{iface := #{name := term(), link := ethernet | none, lladdr := <<_:48>> | none,
                             mtu := pos_integer(), mtu6 := pos_integer(), hlim := 0..255,
                             finish := erx_net_driver:finisher()},
                  addrs := [{Order :: non_neg_integer(), erx_net_addr:row()}],
                  routes := [erx_net_route:row()]}.

-record(bucket, {rate :: pos_integer(),
                 burst :: pos_integer(),
                 tokens :: non_neg_integer(),      % in token-microseconds
                 at = none :: none | integer()}).  % when they were counted

-record(core, {name :: term(),
               medium :: ethernet | none,        % the driver's link: none on the loopback
               lladdr :: <<_:48>> | none,
               device_mtu :: pos_integer(),
               mtu :: pos_integer(),
               finish :: erx_net_driver:finisher(),  % the driver's, written into the row
               dhcp :: boolean(),
               link :: up | down,                % the driver's latest link state
               addrs = [] :: [{non_neg_integer(), erx_net_addr:row()}],
               order = 0 :: non_neg_integer(),   % the next address's place
               routes = [] :: [erx_net_route:row()],
               lease = none :: none | erx_dhcp4_core:lease(),
               arp :: erx_arp:table(),
               syncache = erx_tcp_syncache:new() :: erx_tcp_syncache:syncache(),
               lim :: erx_net_bandlim:lim(),
               bucket :: #bucket{},
               gen :: erx_net_rand:gen(),
               snapshot = none :: none | erx_net_frame:snapshot(),
               config_gen = none :: none | non_neg_integer(),
               counters = #{} :: #{atom() => pos_integer()}}).

-opaque core() :: #core{}.

%% --- The core --------------------------------------------------------------------

-doc """
The core of interface `name` over the link its driver described, with generator `gen`
and configuration `config`. Its first step is `start`. The loopback interface's link is
`none`, with no link-layer address, and its IPv4 configuration is static.
""".
-spec new(#{name := term(), link := erx_net_driver:link_info(), gen := erx_net_rand:gen(),
            config := config()}) -> core().
new(#{name := Name,
      link := #{link := Medium, lladdr := Lladdr, mtu := Mtu, state := Link, finish := Finish},
      gen := Gen0, config := #{ip4 := Ip4} = Config})
  when Medium =:= ethernet, is_binary(Lladdr), byte_size(Lladdr) =:= 6;
       Medium =:= none, Lladdr =:= none, Ip4 =/= dhcp ->
    #{rate := Rate, burst := Burst} = maps:get(ingress, Config, ?INGRESS_DEFAULT),
    {LimGen, Gen} = erx_net_rand:split(Gen0),
    Core = #core{name = Name, medium = Medium, lladdr = Lladdr, device_mtu = Mtu, mtu = Mtu,
                 finish = Finish,
                 dhcp = Ip4 =:= dhcp, link = Link, arp = erx_arp:new(), lim = erx_net_bandlim:new(LimGen),
                 bucket = #bucket{rate = Rate, burst = Burst, tokens = Burst * ?TOKEN},
                 gen = Gen},
    case Ip4 of
        dhcp ->
            Core;
        #{addr := Addr, plen := Plen} ->
            Gateway = maps:get(gateway, Ip4, none),
            Routes = [#{prefix => <<0:32>>, plen => 0, gateway => Gateway} || Gateway =/= none],
            configure(Addr, Plen, Routes, Core)
    end.

-doc """
What `erx_net_input:classify/2` reads of the interface, without `demux`. Its IPv4
addresses are every address of the stack, its own first and then those of the
configuration copy (`erx_net_frame:addresses/1`), so a packet to another interface's
address is the stack's here too, as the loopback interface's packets to every address
of the stack must be; its broadcast addresses are its own.
""".
-spec view(core()) -> map().
view(#core{name = Name, medium = Medium, lladdr = Lladdr, dhcp = Dhcp, addrs = Addrs,
           snapshot = Snapshot}) ->
    Loopback = Medium =:= none,
    #{link => Medium, lladdr => Lladdr,
      ip4 => #{addrs => stack4([A || {_, #{addr := A}} <- Addrs], Snapshot),
               broadcasts => [B || {_, #{broadcast := B}} <- Addrs],
               loopback => Loopback},
      ip6 => #{addrs => [], notready => [], loopback => Loopback, zone => Name},
      groups => [], dhcp => Dhcp}.

%% The interface's own IPv4 addresses, then the rest of the stack's: the copy may lag
%% the interface's own rows, and holds them once it has caught up.
stack4(Own, none) ->
    Own;
stack4(Own, Snapshot) ->
    Own ++ [A || <<_:32>> = A <- erx_net_frame:addresses(Snapshot), not lists:member(A, Own)].

-doc """
The step's context: the time in microseconds, and for a segment to a listener the stack's
secrets, which erx_net_if reads from erx_net_tables for that segment alone.
""".
-type context() :: #{now := integer(), secrets => erx_tcp_syncache:secrets()}.

-doc "When the core next needs `{expired, Now}`, in microseconds.".
-spec next_deadline(core()) -> integer() | infinity.
next_deadline(#core{arp = Arp, syncache = Cache}) ->
    %% An integer is less than any atom, so min/2 keeps a deadline over infinity.
    case min(erx_arp:next_deadline(Arp), erx_tcp_syncache:next_deadline(Cache)) of
        infinity -> infinity;
        Ms -> Ms * 1000
    end.

-doc "The core's next value and the actions to perform, in order, after `Event`.".
-spec step(event(), core(), context()) -> {core(), [action()]}.
step(start, Core, _Ctx) ->
    {Core, [publish(Core) | announce(Core)]};
step({local, Pending}, Core, Ctx) ->
    local(Pending, Core, Ctx);
step({resolve, NextHop, _Src, Packets}, Core, #{now := Now}) ->
    resolve(NextHop, Packets, Core, Now);
step({reset, NextHop, _Src, Packets}, Core0, #{now := Now}) when is_binary(NextHop) ->
    case rst_allowed(Core0, Now) of
        {allow, Core} -> resolve(NextHop, Packets, Core, Now);
        {deny, Core} -> {count(rst_limited, Core), []}
    end;
step(charge_rst, Core0, #{now := Now}) ->
    {_, Core} = rst_allowed(Core0, Now),
    {Core, []};
step({hint, NextHop}, #core{arp = Arp} = Core, _Ctx) when is_binary(NextHop) ->
    {Core#core{arp = erx_arp:hint(NextHop, Arp)}, []};
step({config, Gen, Snapshot}, Core, _Ctx) ->
    {Core#core{config_gen = Gen, snapshot = Snapshot}, []};
step({link, State}, #core{dhcp = true} = Core, _Ctx) ->
    {Core#core{link = State}, [{dhcp, {link, State}}]};
step({link, State}, Core, _Ctx) ->
    {Core#core{link = State}, []};
step({dhcp, Action}, #core{dhcp = true} = Core, #{now := Now}) ->
    dhcp(Action, Core, Now);
step({admin, Request, From}, Core, _Ctx) ->
    {Core, [{reply, From, admin(Request, Core)}]};
step({drop, Reason}, Core, _Ctx) when is_atom(Reason) ->
    {count(Reason, Core), []};
%% The units of the merge a batch held and the segments in them, the totals the benchmarks
%% read as segments per merged unit (docs/design-network-fastpath.md, "Verification").
step({merged, Units, Segments}, Core, _Ctx) ->
    {add(units, Units, add(unit_segments, Segments, Core)), []};
%% A handshake whose listener had no accept credit left: tcp_sc_rst_sock_fail's RST
%% (tcp_syncache.c:215, tcp_input.c:1114-1135), under the RST limit.
step({accept_refused, {Ours, _, Peer, _}, {#tcp{} = Tcp, Payload, _Ecn, _Link}}, Core,
     #{now := Now}) ->
    dropwithreset(Peer, Ours, Tcp, Payload, count(accept_refused, Core), Now);
step({expired, Now}, #core{arp = Arp0, syncache = Cache0} = Core0, _Ctx) ->
    {Arp, ArpActions} = erx_arp:expired(Now div 1000, arp_iface(Core0), Arp0),
    {Core1, Out} = arp_actions(ArpActions, Core0#core{arp = Arp}),
    {Cache, Actions} = erx_tcp_syncache:expired(Now div 1000, Cache0),
    {Core, More} = syncache_actions(Actions, Core1#core{syncache = Cache}, Now),
    {Core, Out ++ More};
step(_Event, Core, _Ctx) ->
    {count(unsupported, Core), []}.

%% --- Receiving -------------------------------------------------------------------

%% A local frame spends a token unless it is a reply the table awaits, is verified, and
%% gets its token back when the check fails.
local(Pending, Core0, #{now := Now} = Ctx) ->
    case charge(Pending, Core0, Now) of
        {refused, Core} ->
            {count(ingress, Core), []};
        {Charged, Core} ->
            case erx_net_input:verify(Pending) of
                {ok, Item} -> verified(Item, Core, Ctx);
                {drop, Reason} -> {count(Reason, refund(Charged, Core)), []}
            end
    end.

charge(Pending, #core{arp = Arp, bucket = Bucket0} = Core, Now) ->
    Awaited = case erx_net_input:arp_reply(Pending) of
                  {ok, Spa} -> erx_arp:awaiting(Spa, Arp);
                  none -> false
              end,
    #bucket{tokens = Tokens} = Bucket = refill(Bucket0, Now),
    if
        Awaited -> {free, Core#core{bucket = Bucket}};
        Tokens >= ?TOKEN -> {token, Core#core{bucket = Bucket#bucket{tokens = Tokens - ?TOKEN}}};
        true -> {refused, Core#core{bucket = Bucket}}
    end.

refill(#bucket{at = none} = B, Now) ->
    B#bucket{at = Now};
refill(#bucket{rate = Rate, burst = Burst, tokens = Tokens, at = At} = B, Now) when Now > At ->
    B#bucket{tokens = min(Burst * ?TOKEN, Tokens + (Now - At) * Rate), at = Now};
refill(B, _Now) ->
    B.

refund(free, Core) -> Core;
refund(token, #core{bucket = #bucket{tokens = T, burst = Burst} = B} = Core) ->
    Core#core{bucket = B#bucket{tokens = min(Burst * ?TOKEN, T + ?TOKEN)}}.

%% A segment for a listener goes to the syncache; every other item needs the time alone.
verified({tcp, #{family := inet} = Head, #tcp{} = Tcp, Payload, #{listener := _} = Entry}, Core,
         Ctx) ->
    listener(Head, Tcp, Payload, Entry, Core, Ctx);
verified(Item, Core, #{now := Now}) ->
    item(Item, Core, Now).

item({arp, Arp}, #core{arp = Table0} = Core, Now) ->
    {Table, Actions} = erx_arp:input(Arp, Now div 1000, arp_iface(Core), Table0),
    arp_actions(Actions, Core#core{arp = Table});
item({icmp, #{family := inet, ip := Ip, reply := Reply}, #icmp4{} = Icmp, Rest},
     #core{lim = Lim0} = Core0, Now) ->
    {Actions, Lim} = erx_icmp4:input(Ip, Reply, Icmp, Rest, icmp_ctx(Now), Lim0),
    icmp_actions(Actions, Core0#core{lim = Lim}, Now);
item({dhcp, _Ip, _Udp, Payload}, #core{dhcp = true} = Core, _Now) ->
    case erx_dhcp4_wire:decode(Payload) of
        {ok, Msg} -> {Core, [{dhcp, {reply, Msg}}]};
        {error, Reason} -> {count(Reason, Core), []}
    end;
item({udp, #{family := inet, ip := Ip}, #udp{}, Datagram}, #core{lim = Lim0} = Core, Now) ->
    %% udp_input's port unreachable (udp_usrreq.c), under icmp_unreach's limit.
    Packet = <<(erx_ip4_wire:encode(Ip))/binary, Datagram/binary>>,
    {Actions, Lim} = erx_icmp4:error({unreach, 3}, Packet, icmp_ctx(Now), Lim0),
    icmp_actions(Actions, count(port_unreach, Core#core{lim = Lim}), Now);
item({tcp, #{family := inet, link := unicast, src := Src, dst := Dst}, #tcp{} = Tcp, Payload, none},
     Core, Now) ->
    closed_port(Src, Dst, Tcp, Payload, Core, Now);
item({tcp, _Head, #tcp{}, _Payload, none}, Core, _Now) ->
    {count(no_reply, Core), []};
item(_Item, Core, _Now) ->
    {count(unsupported, Core), []}.

%% tcp_dropwithreset for a segment no connection holds (tcp_input.c): nothing for a RST;
%% for an ACK, a RST at the acknowledged number; otherwise a RST acknowledging all the
%% segment occupied, its SYN and FIN included; each within the RST limit. Classification
%% already refused a segment to a broadcast or multicast destination.
closed_port(Peer, Ours, Tcp, Payload, Core, Now) ->
    dropwithreset(Peer, Ours, Tcp, Payload, count(closed_port, Core), Now).

dropwithreset(_Peer, _Ours, #tcp{flags = Flags}, _Payload, Core, _Now)
  when Flags band ?TH_RST =/= 0 ->
    {Core, []};
dropwithreset(Peer, Ours, Tcp, Payload, Core0, Now) ->
    case rst_allowed(Core0, Now) of
        {deny, Core} ->
            {count(rst_limited, Core), []};
        {allow, Core} ->
            Rst = dropwithreset_rst(Tcp, Payload),
            with_path(Peer, Ours, Core,
                      fun(Path, Gen) -> erx_net_frame:tcp(Path, [Rst], Gen) end, Now)
    end.

dropwithreset_rst(#tcp{sport = Sport, dport = Dport, flags = Flags, ack = Ack}, _Payload)
  when Flags band ?TH_ACK =/= 0 ->
    rst(Dport, Sport, Ack, 0, ?TH_RST);
dropwithreset_rst(#tcp{sport = Sport, dport = Dport, flags = Flags, seq = Seq}, Payload) ->
    Len = byte_size(Payload) + (Flags band ?TH_SYN) div ?TH_SYN + (Flags band ?TH_FIN),
    rst(Dport, Sport, 0, erx_tcp_seq:wire(Seq + Len), ?TH_RST bor ?TH_ACK).

rst(Sport, Dport, Seq, Ack, Flags) ->
    {#tcp{sport = Sport, dport = Dport, seq = Seq, ack = Ack, flags = Flags, win = 0, urp = 0},
     #{ecn => 0, df => true}, []}.

rst_allowed(#core{lim = Lim0} = Core, Now) ->
    {Verdict, Lim} = erx_net_bandlim:check(tcp_rst, Now div 1000, Lim0),
    {Verdict, Core#core{lim = Lim}}.

%% --- Passive open ------------------------------------------------------------------

%% tcp_input's branch for a listen socket (tcp_input.c:1069-1229), by the segment's flags:
%% ACK without SYN or RST to syncache_expand; a RST to syncache_chkrst; a segment without
%% SYN, or with SYN and ACK, dropped (:1181, :1192); SYN, with FIN too since drop_synfin is
%% 0 (:157, :1211), to syncache_add. The checks of a SYN that read the four-tuple alone are
%% the syncache's (:1295-1338); the input row already dropped a link-layer broadcast or
%% multicast and a broadcast or multicast destination (:1288, :1326-1338). The syncache
%% keeps milliseconds.
listener(#{src := Src, dst := Dst} = Head,
         #tcp{sport = Sport, dport = Dport, flags = Flags} = Tcp, Payload,
         #{listener := Listener} = Entry, #core{syncache = Cache0} = Core0,
         #{now := Now, secrets := Secrets}) ->
    Conn = {Dst, Dport, Src, Sport},
    NowMs = Now div 1000,
    CacheCtx = #{now => NowMs, secrets => Secrets},
    if
        Flags band (?TH_RST bor ?TH_ACK bor ?TH_SYN) =:= ?TH_ACK ->
            {Outcome, Cache, Actions} =
                erx_tcp_syncache:expand(Conn, Tcp, Listener, CacheCtx, Cache0),
            {Core, Out} = syncache_actions(Actions, Core0#core{syncache = Cache}, Now),
            Segment = erx_net_input:segment(Head, Tcp, Payload),
            {Core1, More} = expanded(Outcome, Conn, Segment, Entry, Core, Now),
            {Core1, Out ++ More};
        Flags band ?TH_RST =/= 0 ->
            {Cache, Actions} = erx_tcp_syncache:chkrst(Conn, Tcp, NowMs, Cache0),
            syncache_actions(Actions, Core0#core{syncache = Cache}, Now);
        Flags band ?TH_SYN =:= 0 ->
            {count(listen_no_syn, Core0), []};
        Flags band ?TH_ACK =/= 0 ->
            {count(listen_syn_ack, Core0), []};
        true ->
            {Cache, Actions} = erx_tcp_syncache:add(Conn, Tcp, Listener, CacheCtx, Cache0),
            syncache_actions(Actions, Core0#core{syncache = Cache}, Now)
    end.

%% syncache_expand's result (tcp_input.c:1081-1135): a handshake becomes the connection,
%% with a generator split from the interface's; a drop is silent; a reset is the RST of
%% tcp_dropwithreset once the lookup without wildcard finds no connection either.
expanded({ok, Handshake}, Conn, Segment, Entry, #core{gen = Gen0} = Core, _Now) ->
    {ConnGen, Gen} = erx_net_rand:split(Gen0),
    {count(syncache_completed, Core#core{gen = Gen}),
     [{accept, Entry, Conn, Handshake, Segment, ConnGen}]};
expanded(drop, _Conn, _Segment, _Entry, Core, _Now) ->
    {count(syncache_dropped, Core), []};
expanded(reset, {Ours, _, Peer, _}, {Tcp, Payload, _Ecn, _Link}, _Entry, Core, Now) ->
    dropwithreset(Peer, Ours, Tcp, Payload, count(syncache_reset, Core), Now).

%% The syncache's actions: a SYN-ACK or challenge ACK leaves from the four-tuple's local
%% end over the path to its foreign end; a challenge ACK charges the RST limit and is sent
%% whatever it answers (tcp_challenge_ack_check), and charge_rst only charges it. The flow
%% label is IPv6's and has no use over IPv4.
syncache_actions(Actions, Core0, Now) ->
    lists:foldl(fun(Action, {Core, Acc}) ->
                        {Core1, More} = syncache_action(Action, Core, Now),
                        {Core1, Acc ++ More}
                end, {Core0, []}, Actions).

syncache_action({send, Conn, Tcp, _FlowLabel}, Core, Now) ->
    send_tcp(Conn, Tcp, Core, Now);
syncache_action({challenge_ack, Conn, Tcp, _FlowLabel}, Core0, Now) ->
    {_, Core} = rst_allowed(Core0, Now),
    send_tcp(Conn, Tcp, Core, Now);
syncache_action(charge_rst, Core0, Now) ->
    {_, Core} = rst_allowed(Core0, Now),
    {Core, []}.

send_tcp({Ours, _, Peer, _}, Tcp, Core, Now) ->
    with_path(Peer, Ours, Core,
              fun(Path, Gen) -> erx_net_frame:tcp(Path, [{Tcp, #{ecn => 0, df => true}, []}], Gen) end,
              Now).

icmp_ctx(Now) ->
    #{now => Now div 1000, time_of_day => (Now div 1000) rem 86400000}.

%% erx_icmp4's actions: messages to send; reports and redirects have no consumer here yet.
icmp_actions(Actions, Core0, Now) ->
    lists:foldl(fun({send, Out, Payload}, {Core, Acc}) ->
                        {Core1, More} = send_ip(Out, Payload, Core, Now),
                        {Core1, Acc ++ More};
                   (_Other, {Core, Acc}) ->
                        {count(unsupported, Core), Acc}
                end, {Core0, []}, Actions).

%% --- DHCP --------------------------------------------------------------------------

dhcp({send, broadcast, From, Msg}, Core, _Now) ->
    broadcast_dhcp(From, Msg, Core);
dhcp({send, Server, From, Msg}, Core, Now) ->
    Datagram = #{sport => ?DHCP_CLIENT_PORT, dport => ?DHCP_SERVER_PORT,
                 payload => erx_dhcp4_wire:encode(Msg)},
    send_udp(Server, From, Datagram, Core, Now);
dhcp({configure, #{addr := Addr, mask := Mask, routes := Routes, mtu := Mtu} = Lease}, Core0, _Now) ->
    Core = configure(Addr, masklen(Mask), Routes, Core0#core{lease = Lease, mtu = Mtu}),
    {Core, [publish(Core) | announce(Core)]};
dhcp(unconfigure, #core{device_mtu = Mtu} = Core0, _Now) ->
    Core = Core0#core{addrs = [], routes = [], lease = none, mtu = Mtu},
    {Core, [publish(Core)]}.

%% A message before the client holds an address: from 0.0.0.0 or its address to the
%% limited broadcast, framed to the Ethernet broadcast address without a path.
broadcast_dhcp(From, Msg, #core{lladdr = Lladdr, mtu = Mtu, gen = Gen0} = Core) ->
    Sum = erx_ip4_wire:pseudo_sum(From, ?BROADCAST4, 0, ?PROTO_UDP),
    Udp = erx_udp_wire:encode(#udp{sport = ?DHCP_CLIENT_PORT, dport = ?DHCP_SERVER_PORT},
                              erx_dhcp4_wire:encode(Msg), Sum),
    Out = #{src => From, dst => ?BROADCAST4, proto => ?PROTO_UDP, ttl => ?DHCP_TTL},
    case erx_ip4:output(Out, Udp, Mtu, Gen0) of
        {ok, Packets, Gen} ->
            Frames = erx_net_frame:link(#{link => ethernet, lladdr => Lladdr}, ?ETHER_BROADCAST,
                                        Packets),
            {Core#core{gen = Gen}, [{transmit, Frames}]};
        {error, Reason} ->
            {count(Reason, Core), []}
    end.

%% The address, its subnet's route and further routes, replacing what was configured. Only
%% Ethernet has a broadcast address: the loopback interface has no IFF_BROADCAST, so
%% its address gets none (in.c:597).
configure(Addr, Plen, Routes, #core{name = Name, medium = Medium, order = Order} = Core) ->
    Subnet = erx_net_addr:masked(Addr, Plen),
    Row0 = #{addr => Addr, plen => Plen, ifname => Name, flags => []},
    Row = case Plen < 31 andalso Medium =:= ethernet of
              true -> Row0#{broadcast => broadcast(Subnet, Plen)};
              false -> Row0
          end,
    OnLink = #{prefix => Subnet, plen => Plen, gateway => none},
    Core#core{addrs = [{Order, Row}], order = Order + 1,
              routes = [R#{ifname => Name, metric => 0} || R <- [OnLink | Routes]]}.

broadcast(<<Net:32>>, Plen) ->
    <<(Net bor ((1 bsl (32 - Plen)) - 1)):32>>.

masklen(<<Mask:32>>) ->
    32 - length(lists:takewhile(fun(Bit) -> Mask band (1 bsl Bit) =:= 0 end, lists:seq(0, 31))).

%% --- Sending -----------------------------------------------------------------------

%% A UDP datagram from Src over a path to Dst.
send_udp(Dst, Src, #{sport := Sport, dport := Dport, payload := Payload}, Core, Now) ->
    with_path(Dst, Src, Core,
              fun(Path, Gen) -> erx_net_frame:udp(Path, Sport, Dport, Payload, Gen) end, Now).

%% An IP datagram erx_icmp4 built.
send_ip(#{src := Src, dst := Dst, proto := Proto} = Out, Payload, Core, Now) ->
    Tos = maps:get(tos, Out, 0),
    with_path(Dst, Src, Core,
              fun(Path, Gen) -> erx_net_frame:ip(Path#{tos := Tos}, Proto, Payload, Gen) end, Now).

with_path(_Dst, _Src, #core{snapshot = none} = Core, _Build, _Now) ->
    {count(no_route, Core), []};
with_path(Dst, Src, #core{name = Name, snapshot = Snapshot, gen = Gen0} = Core, Build, Now) ->
    case erx_net_frame:path(Dst, #{src => Src}, Snapshot) of
        {ok, #{iface := #{name := Name}} = Path} ->
            case Build(Path, Gen0) of
                {ok, Packets, Gen} -> address(Path, Packets, Core#core{gen = Gen}, Now);
                {error, Reason} -> {count(Reason, Core), []}
            end;
        {ok, _OtherInterface} ->
            {count(other_interface, Core), []};
        {error, Reason} ->
            {count(Reason, Core), []}
    end.

%% Packets over a path: framed at once to a fixed link address, else through erx_arp.
address(#{link := {fixed, LinkAddr}} = _Path, Packets, Core, _Now) ->
    {Core, [{transmit, frames(LinkAddr, Packets, Core)}]};
address(#{link := neighbour, next_hop := NextHop}, Packets, Core, Now) ->
    resolve(NextHop, Packets, Core, Now).

resolve(NextHop, Packets, Core0, Now) when is_binary(NextHop) ->
    lists:foldl(fun(Packet, {#core{arp = Arp0} = Core, Acc}) ->
                        {Arp, Actions} = erx_arp:resolve(NextHop, Packet, Now div 1000,
                                                         arp_iface(Core), Arp0),
                        {Core1, More} = arp_actions(Actions, Core#core{arp = Arp}),
                        {Core1, Acc ++ More}
                end, {Core0, []}, Packets).

frames(LinkAddr, Packets, #core{medium = Medium, lladdr = Lladdr}) ->
    erx_net_frame:link(#{link => Medium, lladdr => Lladdr}, LinkAddr, Packets).

%% --- ARP ---------------------------------------------------------------------------

arp_iface(#core{lladdr = Lladdr, addrs = Addrs}) ->
    #{lladdr => Lladdr, addrs => [{A, P} || {_, #{addr := A, plen := P}} <- Addrs]}.

%% A gratuitous ARP for each address, on Ethernet; the loopback interface has no ARP.
announce(#core{medium = none}) ->
    [];
announce(#core{addrs = Addrs} = Core) ->
    {_, Actions} = arp_actions(lists:append([erx_arp:announce(A, arp_iface(Core))
                                             || {_, #{addr := A}} <- Addrs]), Core),
    Actions.

arp_actions(Actions, Core0) ->
    lists:foldl(fun(Action, {Core, Acc}) ->
                        case arp_action(Action, Core) of
                            {count, Reason} -> {count(Reason, Core), Acc};
                            Out -> {Core, Acc ++ [Out]}
                        end
                end, {Core0, []}, Actions).

arp_action({send_arp, Dst, #arp{} = Arp}, #core{lladdr = Lladdr}) ->
    Header = erx_net_eth:encode(#eth{dst = Dst, src = Lladdr, type = ?ETHERTYPE_ARP}),
    {transmit, [[Header, erx_arp_wire:encode(Arp)]]};
arp_action({send, Mac, Packets}, Core) ->
    {transmit, frames(Mac, Packets, Core)};
arp_action({publish, Ip, Mac, Freshness}, _Core) ->
    {neigh, publish, Ip, Mac, Freshness};
arp_action({unpublish, Ip}, _Core) ->
    {neigh, unpublish, Ip};
arp_action({conflict, _Ip, _Mac}, _Core) ->
    {count, arp_conflict}.

%% --- Publishing and administration -------------------------------------------------

publish(#core{name = Name, medium = Medium, lladdr = Lladdr, mtu = Mtu, finish = Finish,
              addrs = Addrs, routes = Routes}) ->
    {publish, #{iface => #{name => Name, link => Medium, lladdr => Lladdr, mtu => Mtu,
                           mtu6 => Mtu, hlim => ?HLIM, finish => Finish},
                addrs => Addrs, routes => Routes}}.

admin(counters, #core{counters = Counters}) -> {ok, Counters};
admin(lease, #core{lease = Lease}) -> {ok, Lease};
admin(status, Core) -> {ok, status(Core)};
admin(_Request, _Core) -> {error, enotsup}.

status(#core{name = Name, lladdr = Lladdr, mtu = Mtu, link = Link, dhcp = Dhcp, addrs = Addrs,
             routes = Routes, lease = Lease}) ->
    {Dns, Search} = case Lease of
                        #{dns := D, search := S} -> {D, S};
                        none -> {[], []}
                    end,
    #{name => Name, lladdr => Lladdr, mtu => Mtu, link => Link,
      config => case Dhcp of true -> dhcp; false -> static end,
      addrs => [Row || {_, Row} <- Addrs], routes => Routes, dns => Dns, search => Search}.

count(Reason, Core) ->
    add(Reason, 1, Core).

add(Name, By, #core{counters = Counters} = Core) ->
    Core#core{counters = maps:update_with(Name, fun(N) -> N + By end, By, Counters)}.
