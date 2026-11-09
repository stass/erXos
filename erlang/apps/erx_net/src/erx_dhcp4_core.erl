%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dhcp4_core).
-moduledoc """
The DHCP client of one interface (RFC 2131 sections 3.1, 4.1 and 4.4;
docs/design-network-stack.md, "Addresses and routes"), a pure state machine written from
the RFC with FreeBSD's `dhclient` as the behavioural reference. `erx_dhcp4` keeps the
value, calls `step/3` with the current monotonic time in milliseconds, performs the actions
in order and arms its timer at `next_deadline/1`.

An event is `timeout`, the timer reaching the deadline, or `{reply, Msg}`, a message the
interface process passed on (it passes only replies whose transaction id is `xid/1`, but
`step/3` checks that again with the hardware address, so the property does not rest on
the caller). An action is

* `{send, To, From, Msg}`: the interface frames `Msg` from `From`, port 68, to `To`, port
  67, where `To` is `broadcast` or the server's address;
* `{configure, Lease}`: the interface's IPv4 address, mask, routes, MTU, name servers and
  search list are now `Lease`'s, replacing any lease configured before; it is not
  repeated for a renewal that changes none of them;
* `unconfigure`: the lease has ended or the server refused it; the interface drops it and
  goes back to its device's MTU.

The phases are RFC 2131's (figure 5), without INIT-REBOOT, since the client keeps no lease
across a restart:

* `init`: on its deadline, a DISCOVER with a fresh transaction id, then `selecting`.
* `selecting`: the first acceptable OFFER (an address that can be a host's, and a server
  identifier) is taken, as `dhclient` does with its default `select-timeout` of 0, and
  answered with a broadcast REQUEST for it, then `requesting`. Without one the DISCOVER is
  sent again.
* `requesting`: an acceptable ACK for the offered address from the offering server
  configures the lease, then `bound`; a NAK from the
  selected server returns to `init`, which starts again after a retransmission delay;
  after five REQUESTs without an answer the client starts again with a DISCOVER.
* `bound`: at T1, a REQUEST unicast to the server with a fresh transaction id, then
  `renewing`.
* `renewing` and `rebinding`: an acceptable ACK for the leased address, from the lease's
  server when renewing and from any server when rebinding, renews the lease, then
  `bound`; a NAK unconfigures it and returns to `init`. Retransmissions wait half the time
  left to T2 (renewing) or to the lease's end (rebinding), at least 60 seconds or the time
  left (section 4.4.5); at T2 the REQUEST is broadcast instead, and at the lease's end the
  lease is unconfigured and a DISCOVER starts again.

Retransmissions in `selecting` and `requesting` wait 4 seconds, doubling to 64, each moved
by a uniform delay of -1 to +1 second (section 4.1). The transaction ids and these delays
come from the `erx_net_rand` generator in the state. RFC 4.4.1's random wait of one to
ten seconds before the first DISCOVER is not made, as `dhclient` does not make it. Nor is
the offered address probed with ARP before it is used (RFC 2131 4.4.1, RFC 5227):
`dhclient`'s `ARPCHECK` step does nothing in its stock script. The interface announces the
address with a gratuitous ARP when it configures it, and erx_arp reports another host
using it as a conflict.

A lease is untrusted input. The ACK's options are checked by erx_dhcp4_wire; here the
address and the server identifier must be ones a host can hold (not in 0.0.0.0/8,
loopback, multicast, class E or the limited broadcast), and the ACK must carry the lease
time and server identifier RFC 2131 section 3.1.5 requires. Without a mask, or with a
mask of /0, the address's classful mask is used, as FreeBSD's `in_aifaddr_ioctl` does
when none is given (`in.c`). Under a mask shorter than /31 the address may be neither its
subnet's network nor its broadcast address. What the lease configures:

* routes: the classless static routes (option 121) when the ACK has them, and then the
  routers option is ignored (RFC 3442 section 3); otherwise a default route to the first
  router on the subnet. Under a /32 mask no router is on the subnet, so the first
  router other than the client gets a host route on the link and the default route,
  as `dhclient-script` adds them.
  The classless routes are taken in order, as `dhclient-script` adds them, and at most
  32 are kept. A gateway of 0.0.0.0 puts the route's destinations on the link (no
  gateway); any other must be a next hop on the link: inside the subnet or an on-link
  route kept before it, and neither the client's own address nor the network or
  broadcast address of a prefix that holds it. A route is dropped when its gateway is
  not, when its prefix already has a route (the route table holds one per prefix and
  interface), when its prefix lies inside 0.0.0.0/8, 127.0.0.0/8 or 224.0.0.0/3, which
  no router reaches for this host, or when it is the subnet's own route, which the
  address's configuration owns. A router equal to the client's own address is ignored;
  `dhclient-script` makes it an on-link default route instead;
* the MTU: option 26, at least 68 by erx_dhcp4_wire's check, and no more than the
  device's MTU given to `new/4`, which it is when the ACK has none;
* name servers: the first three host addresses, as many as the resolver reads
  (`MAXNS`);
* the search list: the domain name option's names, which the network domain hands
  `inet_db` beside the name servers, as `dhclient-script` writes them to resolv.conf's
  `search` line.

Lease times count from the first REQUEST of the exchange (section 4.4.1). A lease
shorter than 60 seconds counts as 60, as in `dhclient`'s `dhcpack`, and a T1 and T2
the server gives are used only when
30 s =< T1 < T2 < the lease time; otherwise both are the defaults, half and
seven-eighths of the lease (section 4.4.5). So a server cannot make the client renew,
and configure again, more often than every 30 seconds. An infinite lease (16#ffffffff) is
never renewed.
""".

-include("erx_dhcp4_wire.hrl").

-export([new/4, step/3, next_deadline/1, xid/1]).

-export_type([core/0, event/0, action/0, lease/0, route/0]).

-define(RETRANSMIT_FIRST_MS, 4000).
-define(RETRANSMIT_MAX_MS, 64000).
-define(JITTER_MS, 1000).
-define(REQUEST_SENDS, 5).
-define(RENEW_MIN_MS, 60000).
-define(LEASE_MIN_S, 60).
-define(RENEW_MIN_S, 30).
-define(ROUTES_MAX, 32).
-define(DNS_MAX, 3).
-define(MTU_MIN, 68).
-define(LEASE_INFINITE, 16#ffffffff).
-define(HTYPE_ETHER, 1).
-define(ANY, <<0:32>>).
-define(HOST_MASK, <<255, 255, 255, 255>>).
%% Mask, classless routes, routers, name servers, domain, MTU, lease time, server, T1, T2
%% (RFC 2132); the classless routes come before the routers, as RFC 3442 section 3 asks.
-define(PARAMS, <<1, 121, 3, 6, 15, 26, 51, 54, 58, 59>>).

-type phase() :: init | selecting | requesting | bound | renewing | rebinding.

-doc """
A route the lease installs on its interface, an erx_net_route row without the interface
and metric: destinations within Prefix/Plen go to Gateway, or are on the link when it is
`none`.
""".
-type route() :: #{prefix := <<_:32>>, plen := 0..32, gateway := <<_:32>> | none}.

-doc """
What the interface is configured with: `search` is the resolver's search list, empty
when the server names no domain, and `mtu` the device's MTU when the server gives none.
""".
-type lease() :: #{addr := <<_:32>>, mask := <<_:32>>, routes := [route()],
                   mtu := ?MTU_MIN..16#ffff, dns := [<<_:32>>], search := [binary()],
                   server := <<_:32>>}.

-type event() :: timeout | {reply, #dhcp4{}}.

-type action() :: {send, broadcast | <<_:32>>, From :: <<_:32>>, #dhcp4{}}
                | {configure, lease()}
                | unconfigure.

%% The times of a lease, in the step's milliseconds; infinity for an infinite lease.
-record(times, {t1 :: integer() | infinity,
                t2 :: integer() | infinity,
                expiry :: integer() | infinity}).

-record(core, {mac :: <<_:48>>,
               mtu :: ?MTU_MIN..16#ffff,   % the device's, the most a lease may set
               gen :: erx_net_rand:gen(),
               phase = init :: phase(),
               xid = none :: none | 0..16#ffffffff,
               deadline :: integer() | infinity,
               began = 0 :: integer(),     % when the exchange began, for `secs`
               asked = 0 :: integer(),     % the exchange's first REQUEST, the lease's base
               sends = 0 :: non_neg_integer(),
               offer = none :: none | #dhcp4{},
               lease = none :: none | lease(),
               times = none :: none | #times{}}).

-opaque core() :: #core{}.

-doc """
A client for the interface with hardware address `Mac` and device MTU `Mtu`, starting at
`Now`.
""".
-spec new(<<_:48>>, ?MTU_MIN..16#ffff, erx_net_rand:gen(), integer()) -> core().
new(<<_:48>> = Mac, Mtu, Gen, Now) when is_integer(Mtu), Mtu >= ?MTU_MIN, Mtu =< 16#ffff ->
    #core{mac = Mac, mtu = Mtu, gen = Gen, deadline = Now}.

-doc "When the client next needs a `timeout`.".
-spec next_deadline(core()) -> integer() | infinity.
next_deadline(#core{deadline = Deadline}) -> Deadline.

-doc "The outstanding transaction's id, the only one a reply may carry.".
-spec xid(core()) -> none | 0..16#ffffffff.
xid(#core{xid = Xid}) -> Xid.

-doc "The client's next state and actions after an event at time `Now`.".
-spec step(event(), core(), integer()) -> {core(), [action()]}.
step(timeout, #core{deadline = Deadline} = Core, Now) when Deadline =:= infinity; Now < Deadline ->
    {Core, []};
step(timeout, Core, Now) ->
    expired(Core, Now);
step({reply, Msg}, Core, Now) ->
    case ours(Msg, Core) of
        true -> reply(message_type(Msg), Msg, Core, Now);
        false -> {Core, []}
    end.

ours(#dhcp4{op = reply, htype = ?HTYPE_ETHER, xid = Xid, chaddr = Mac},
     #core{xid = Xid, mac = Mac}) when is_integer(Xid) ->
    true;
ours(_, _) ->
    false.

message_type(#dhcp4{options = #{message_type := Type}}) -> Type.

expired(#core{phase = init} = Core, Now) ->
    discover(Core, Now);
expired(#core{phase = selecting} = Core, Now) ->
    send_discover(Core, Now);
expired(#core{phase = requesting, sends = Sends} = Core, Now) when Sends >= ?REQUEST_SENDS ->
    discover(Core, Now);
expired(#core{phase = requesting} = Core, Now) ->
    send_selecting_request(Core, Now);
expired(#core{phase = bound} = Core, Now) ->
    {Xid, Gen} = draw_xid(Core#core.gen),
    expired(Core#core{phase = renewing, xid = Xid, gen = Gen, began = Now, asked = Now}, Now);
%% The clauses below are tried in order: the lease's end first, then T2, then a plain
%% retransmission of renewing or rebinding.
expired(#core{phase = Phase, times = #times{expiry = Expiry}} = Core, Now)
  when Phase =:= renewing orelse Phase =:= rebinding, Now >= Expiry ->
    {Next, Actions} = discover(Core#core{lease = none, times = none}, Now),
    {Next, [unconfigure | Actions]};
expired(#core{phase = renewing, times = #times{t2 = T2}} = Core, Now) when Now >= T2 ->
    renew(Core#core{phase = rebinding}, Now);
expired(#core{phase = Phase} = Core, Now) when Phase =:= renewing; Phase =:= rebinding ->
    renew(Core, Now).

%% A new exchange: a fresh transaction id and the first DISCOVER.
discover(Core, Now) ->
    {Xid, Gen} = draw_xid(Core#core.gen),
    send_discover(Core#core{phase = selecting, xid = Xid, gen = Gen, began = Now, sends = 0,
                            offer = none}, Now).

send_discover(Core, Now) ->
    Msg = client_message(Core, Now, #{message_type => discover}),
    retransmit({send, broadcast, ?ANY, Msg}, Core, Now).

send_selecting_request(#core{offer = #dhcp4{yiaddr = Addr, options = #{server_id := Server}}} = Core,
                       Now) ->
    Msg = client_message(Core, Now, #{message_type => request, requested_ip => Addr,
                                      server_id => Server}),
    retransmit({send, broadcast, ?ANY, Msg}, first_request(Core, Now), Now).

first_request(#core{sends = 0} = Core, Now) -> Core#core{asked = Now};
first_request(Core, _Now) -> Core.

%% A REQUEST of renewing (unicast) or rebinding (broadcast), from the leased address.
renew(#core{phase = Phase, lease = #{addr := Addr, server := Server}, times = Times} = Core, Now) ->
    Msg = (client_message(Core, Now, #{message_type => request}))#dhcp4{ciaddr = Addr},
    {To, Until} = case Phase of
                      renewing -> {Server, Times#times.t2};
                      rebinding -> {broadcast, Times#times.expiry}
                  end,
    {Core#core{deadline = Now + renew_wait(Until - Now)}, [{send, To, Addr, Msg}]}.

%% Half the time left, but at least a minute or all of it (RFC 2131 section 4.4.5).
renew_wait(Left) -> max(Left div 2, min(Left, ?RENEW_MIN_MS)).

%% Sends one message of selecting or requesting and waits the next backoff for an answer.
retransmit(Send, #core{sends = Sends, gen = Gen} = Core, Now) ->
    Base = min(?RETRANSMIT_FIRST_MS bsl min(Sends, 4), ?RETRANSMIT_MAX_MS),
    {Jitter, Gen1} = erx_net_rand:uniform(2 * ?JITTER_MS + 1, Gen),
    {Core#core{sends = Sends + 1, gen = Gen1, deadline = Now + Base + Jitter - ?JITTER_MS},
     [Send]}.

%% A client message (op request: a DISCOVER or a REQUEST) of the current exchange.
client_message(#core{mac = Mac, xid = Xid, began = Began}, Now, Options) ->
    #dhcp4{op = request, htype = ?HTYPE_ETHER, xid = Xid,
           secs = min((Now - Began) div 1000, 16#ffff), chaddr = Mac,
           options = Options#{client_id => <<?HTYPE_ETHER, Mac/binary>>, params => ?PARAMS}}.

draw_xid(Gen) ->
    {<<Xid:32>>, Gen1} = erx_net_rand:bytes(4, Gen),
    {Xid, Gen1}.

reply(offer, #dhcp4{yiaddr = Addr, options = #{server_id := Server}} = Offer,
      #core{phase = selecting} = Core, Now) ->
    case host_address(Addr) andalso host_address(Server) of
        true -> send_selecting_request(Core#core{phase = requesting, offer = Offer, sends = 0}, Now);
        false -> {Core, []}
    end;
reply(ack, Ack, #core{phase = Phase, lease = Old} = Core, _Now)
  when Phase =:= requesting; Phase =:= renewing; Phase =:= rebinding ->
    case answers(Ack, Core) andalso lease(Ack, Core) of
        {ok, Lease, Times} ->
            {Core#core{phase = bound, xid = none, sends = 0, offer = none, lease = Lease,
                       times = Times, deadline = Times#times.t1},
             configure(Lease, Old)};
        _ ->
            {Core, []}
    end;
reply(nak, #dhcp4{options = Options}, #core{phase = requesting, offer = Offer} = Core, Now) ->
    case {Options, Offer} of
        {#{server_id := Server}, #dhcp4{options = #{server_id := Server}}} -> restart(Core, Now, []);
        _ -> {Core, []}
    end;
reply(nak, #dhcp4{options = #{server_id := _}}, #core{phase = Phase} = Core, Now)
  when Phase =:= renewing; Phase =:= rebinding ->
    restart(Core#core{lease = none, times = none}, Now, [unconfigure]);
reply(_, _, Core, _Now) ->
    {Core, []}.

%% Back to init, which sends a DISCOVER after one retransmission delay.
restart(#core{gen = Gen} = Core, Now, Actions) ->
    {Jitter, Gen1} = erx_net_rand:uniform(2 * ?JITTER_MS + 1, Gen),
    {Core#core{phase = init, xid = none, sends = 0, offer = none, gen = Gen1,
               deadline = Now + ?RETRANSMIT_FIRST_MS + Jitter - ?JITTER_MS},
     Actions}.

%% Whether an ACK answers the REQUEST outstanding: in requesting, for the offered address
%% from the server that offered it; when renewing, for the leased address from the lease's
%% server; when rebinding, which any server may answer, for the leased address.
answers(#dhcp4{yiaddr = Addr, options = #{server_id := Server}},
        #core{phase = requesting, offer = #dhcp4{yiaddr = Addr, options = #{server_id := Server}}}) ->
    true;
answers(#dhcp4{yiaddr = Addr, options = #{server_id := Server}},
        #core{phase = renewing, lease = #{addr := Addr, server := Server}}) ->
    true;
answers(#dhcp4{yiaddr = Addr}, #core{phase = rebinding, lease = #{addr := Addr}}) ->
    true;
answers(_, _) ->
    false.

%% A renewal that changes nothing the interface holds configures nothing again; the
%% server identifier is the client's own, not the interface's.
configure(Lease, none) ->
    [{configure, Lease}];
configure(Lease, Old) ->
    case maps:without([server], Lease) =:= maps:without([server], Old) of
        true -> [];
        false -> [{configure, Lease}]
    end.

lease(#dhcp4{yiaddr = Addr, options = #{lease_time := Seconds, server_id := Server} = Options},
      #core{asked = Asked, mtu = DeviceMtu}) ->
    Mask = mask(Options, Addr),
    case host_address(Addr) andalso host_address(Server) andalso not edge(Addr, subnet(Addr, Mask)) of
        true ->
            Lease = #{addr => Addr,
                      mask => Mask,
                      routes => routes(Options, Addr, Mask),
                      mtu => min(maps:get(mtu, Options, DeviceMtu), DeviceMtu),
                      dns => first(?DNS_MAX, [D || D <- maps:get(dns, Options, []),
                                                   host_address(D)]),
                      search => maps:get(domain_name, Options, []),
                      server => Server},
            T1 = maps:get(t1, Options, none),
            T2 = maps:get(t2, Options, none),
            {ok, Lease, times(Seconds, T1, T2, Asked)};
        false ->
            error
    end;
lease(_, _) ->
    error.

%% The classless routes when the ACK has them (RFC 3442 section 3: the routers option is
%% then ignored), else a default route to the first router on the subnet, or under a /32
%% mask to the first router reached by a host route on the link (`dhclient-script`'s
%% `add_new_routes`).
routes(#{classless_routes := Classless}, Addr, Mask) ->
    Kept = lists:foldl(fun(Route, Installed) -> install(Route, Installed, Addr, Mask) end,
                       [], Classless),
    lists:reverse(Kept);
routes(Options, Addr, Mask) ->
    Routers = maps:get(routers, Options, []),
    OnSubnet = [R || R <- Routers, next_hop(R, Addr, [subnet(Addr, Mask)])],
    Hosts = [R || R <- Routers, host_address(R), R =/= Addr],
    case {OnSubnet, Hosts} of
        {[Router | _], _} -> [default_route(Router)];
        {[], [Router | _]} when Mask =:= ?HOST_MASK ->
            [#{prefix => Router, plen => 32, gateway => none}, default_route(Router)];
        _ -> []
    end.

default_route(Router) -> #{prefix => ?ANY, plen => 0, gateway => Router}.

%% One classless route added after those kept so far, as `dhclient-script` adds them one by
%% one: it is kept unless 32 are, its prefix has a route already, its destination is
%% refused, or its gateway is no next hop on the subnet or on an on-link route kept before
%% it. So only routes the table will hold make a gateway reachable, and the work per route
%% is bounded by the cap.
install(_Route, Installed, _Addr, _Mask) when length(Installed) >= ?ROUTES_MAX ->
    Installed;
install({Prefix, Plen, Router}, Installed, Addr, Mask) ->
    Taken = lists:any(fun(#{prefix := P, plen := L}) -> {P, L} =:= {Prefix, Plen} end, Installed),
    Links = [subnet(Addr, Mask) | [{P, L} || #{prefix := P, plen := L, gateway := none} <- Installed]],
    case not Taken andalso destination_ok(Prefix, Plen, Addr, Mask)
             andalso (Router =:= ?ANY orelse next_hop(Router, Addr, Links)) of
        true -> [#{prefix => Prefix, plen => Plen, gateway => gateway(Router)} | Installed];
        false -> Installed
    end.

%% A classless route's router of 0.0.0.0 puts its destinations on the link (RFC 3442
%% section 3).
gateway(?ANY) -> none;
gateway(Router) -> Router.

%% A next hop on the link: a host address other than the client's, inside a prefix on the
%% link, and the network or broadcast address of no prefix on the link that holds it.
next_hop(Router, Addr, Links) ->
    Holding = [Link || Link <- Links, within(Router, Link)],
    host_address(Router) andalso Router =/= Addr andalso Holding =/= []
        andalso not lists:any(fun(Link) -> edge(Router, Link) end, Holding).

%% A destination a router may take: not inside 0.0.0.0/8, 127.0.0.0/8 or 224.0.0.0/3,
%% which are this host's own or groups, and not the subnet's own route, which the
%% address's configuration owns and a server's route would replace.
destination_ok(<<0, _:24>>, Plen, _Addr, _Mask) when Plen >= 8 -> false;
destination_ok(<<127, _:24>>, Plen, _Addr, _Mask) when Plen >= 8 -> false;
destination_ok(<<7:3, _:29>>, Plen, _Addr, _Mask) when Plen >= 3 -> false;
destination_ok(Prefix, Plen, Addr, Mask) -> {Prefix, Plen} =/= subnet(Addr, Mask).

%% The subnet as a prefix and its length.
subnet(<<A:32>>, <<M:32>>) -> {<<(A band M):32>>, prefix_length(M)}.

prefix_length(Mask) -> 32 - trailing_zeros(Mask, 0).

trailing_zeros(_, 32) -> 32;
trailing_zeros(Mask, N) when Mask band (1 bsl N) =/= 0 -> N;
trailing_zeros(Mask, N) -> trailing_zeros(Mask, N + 1).

within(<<A:32>>, {<<P:32>>, Plen}) -> A bsr (32 - Plen) =:= P bsr (32 - Plen).

%% A prefix's network or broadcast address, which no host holds under a prefix shorter
%% than /31.
edge(<<A:32>>, {_, Plen}) when Plen < 31 ->
    Host = A band (16#ffffffff bsr Plen),
    Host =:= 0 orelse Host =:= 16#ffffffff bsr Plen;
edge(_, _) ->
    false.

mask(#{subnet_mask := Mask}, _Addr) when Mask =/= <<0:32>> -> Mask;
mask(_, Addr) -> classful_mask(Addr).

%% The first N distinct name servers, in order.
first(N, Addrs) -> lists:sublist(lists:uniq(Addrs), N).

times(?LEASE_INFINITE, _, _, _) ->
    #times{t1 = infinity, t2 = infinity, expiry = infinity};
times(Seconds, T1, T2, Asked) ->
    Lease = max(Seconds, ?LEASE_MIN_S),
    {Renew, Rebind} = case {T1, T2} of
                          {T1, T2} when is_integer(T1), is_integer(T2), T1 >= ?RENEW_MIN_S,
                                        T1 < T2, T2 < Lease ->
                              {T1, T2};
                          _ ->
                              {Lease div 2, Lease * 7 div 8}
                      end,
    #times{t1 = Asked + Renew * 1000, t2 = Asked + Rebind * 1000, expiry = Asked + Lease * 1000}.

%% An address a host can hold on a link (RFC 1122 section 3.2.1.3; RFC 1112 section 4).
host_address(<<0, _:24>>) -> false;
host_address(<<127, _:24>>) -> false;
host_address(<<First, _:24>>) when First >= 224 -> false;
host_address(<<_:32>>) -> true.

%% The mask of an address's class, which FreeBSD's in_aifaddr_ioctl applies when none is given.
classful_mask(<<0:1, _:31>>) -> <<255, 0, 0, 0>>;
classful_mask(<<2:2, _:30>>) -> <<255, 255, 0, 0>>;
classful_mask(<<_:32>>) -> <<255, 255, 255, 0>>.
