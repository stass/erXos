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
* `{configure, Lease}`: the interface's IPv4 address, mask, routers, name servers, domain
  and MTU are now `Lease`'s, replacing any lease configured before;
* `unconfigure`: the lease has ended or the server refused it; the interface drops it.

The phases are RFC 2131's (figure 5), without INIT-REBOOT, since the client keeps no lease
across a restart:

* `init`: on its deadline, a DISCOVER with a fresh transaction id, then `selecting`.
* `selecting`: the first acceptable OFFER (an address that can be a host's, and a server
  identifier) is taken, as `dhclient` does with its default `select-timeout` of 0, and
  answered with a broadcast REQUEST for it, then `requesting`. Without one the DISCOVER is
  sent again.
* `requesting`: an acceptable ACK configures the lease, then `bound`; a NAK from the
  selected server returns to `init`, which starts again after a retransmission delay;
  after five REQUESTs without an answer the client starts again with a DISCOVER.
* `bound`: at T1, a REQUEST unicast to the server with a fresh transaction id, then
  `renewing`.
* `renewing` and `rebinding`: an acceptable ACK configures the renewed lease, then
  `bound`; a NAK unconfigures it and returns to `init`. Retransmissions wait half the time
  left to T2 (renewing) or to the lease's end (rebinding), at least 60 seconds or the time
  left (section 4.4.5); at T2 the REQUEST is broadcast instead, and at the lease's end the
  lease is unconfigured and a DISCOVER starts again.

Retransmissions in `selecting` and `requesting` wait 4 seconds, doubling to 64, each moved
by a uniform delay of -1 to +1 second (section 4.1). The transaction ids and these delays
come from the `erx_net_rand` generator in the state. RFC 4.4.1's random wait of one to
ten seconds before the first DISCOVER is not made, as `dhclient` does not make it.

A lease is untrusted input. The ACK's options are checked by erx_dhcp4_wire; here the
address and the server identifier must be ones a host can hold (not in 0.0.0.0/8,
loopback, multicast, class E or the limited broadcast), and the ACK must carry the lease
time and server identifier RFC 2131 section 3.1.5 requires. Without a mask, or with a
mask of /0, the address's classful mask is used, as FreeBSD's `in_aifaddr_ioctl` does
when none is given (`in.c`). Under a mask shorter than /31 the address may be neither its
subnet's network nor its broadcast address. Of the routers, those on the subnet that are
host addresses other than the client's and the subnet's broadcast are kept, the first
four without duplicates; of the name servers, the first three host addresses, as many as
the resolver reads (`MAXNS`).

Lease times count from the first REQUEST of the exchange (section 4.4.1). A lease
shorter than 60 seconds counts as 60, and a T1 and T2 the server gives are used only when
30 s =< T1 < T2 < the lease time; otherwise both are the defaults, half and
seven-eighths of the lease (section 4.4.5). So a server cannot make the client renew,
and configure again, more often than every 30 seconds. An infinite lease (16#ffffffff) is
never renewed.
""".

-include("erx_dhcp4_wire.hrl").

-export([new/3, step/3, next_deadline/1, xid/1]).

-export_type([core/0, event/0, action/0, lease/0]).

-define(RETRANSMIT_FIRST_MS, 4000).
-define(RETRANSMIT_MAX_MS, 64000).
-define(JITTER_MS, 1000).
-define(REQUEST_SENDS, 5).
-define(RENEW_MIN_MS, 60000).
-define(LEASE_MIN_S, 60).
-define(RENEW_MIN_S, 30).
-define(ROUTERS_MAX, 4).
-define(DNS_MAX, 3).
-define(LEASE_INFINITE, 16#ffffffff).
-define(HTYPE_ETHER, 1).
-define(ANY, <<0:32>>).
%% Mask, routers, name servers, domain, MTU, lease time, server, T1, T2 (RFC 2132).
-define(PARAMS, <<1, 3, 6, 15, 26, 51, 54, 58, 59>>).

-type phase() :: init | selecting | requesting | bound | renewing | rebinding.

-doc "What the interface is configured with; `domain` and `mtu` are `none` when not given.".
-type lease() :: #{addr := <<_:32>>, mask := <<_:32>>, routers := [<<_:32>>],
                   dns := [<<_:32>>], domain := binary() | none,
                   mtu := pos_integer() | none, server := <<_:32>>}.

-type event() :: timeout | {reply, #dhcp4{}}.

-type action() :: {send, broadcast | <<_:32>>, From :: <<_:32>>, #dhcp4{}}
                | {configure, lease()}
                | unconfigure.

%% The times of a lease, in the step's milliseconds; infinity for an infinite lease.
-record(times, {t1 :: integer() | infinity,
                t2 :: integer() | infinity,
                expiry :: integer() | infinity}).

-record(core, {mac :: <<_:48>>,
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

-doc "A client for the interface with hardware address `Mac`, starting at `Now`.".
-spec new(<<_:48>>, erx_net_rand:gen(), integer()) -> core().
new(<<_:48>> = Mac, Gen, Now) ->
    #core{mac = Mac, gen = Gen, deadline = Now}.

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
reply(ack, Ack, #core{phase = Phase} = Core, _Now)
  when Phase =:= requesting; Phase =:= renewing; Phase =:= rebinding ->
    case lease(Ack, Core#core.asked) of
        {ok, Lease, Times} ->
            {Core#core{phase = bound, xid = none, sends = 0, offer = none, lease = Lease,
                       times = Times, deadline = Times#times.t1},
             [{configure, Lease}]};
        error ->
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

lease(#dhcp4{yiaddr = Addr, options = #{lease_time := Seconds, server_id := Server} = Options},
      Asked) ->
    Mask = mask(Options, Addr),
    case host_address(Addr) andalso host_address(Server) andalso on_subnet_host(Addr, Mask) of
        true ->
            Lease = #{addr => Addr,
                      mask => Mask,
                      routers => first(?ROUTERS_MAX, [R || R <- maps:get(routers, Options, []),
                                                           router(R, Addr, Mask)]),
                      dns => first(?DNS_MAX, [D || D <- maps:get(dns, Options, []),
                                                   host_address(D)]),
                      domain => maps:get(domain_name, Options, none),
                      mtu => maps:get(mtu, Options, none),
                      server => Server},
            T1 = maps:get(t1, Options, none),
            T2 = maps:get(t2, Options, none),
            {ok, Lease, times(Seconds, T1, T2, Asked)};
        false ->
            error
    end;
lease(_, _) ->
    error.

mask(#{subnet_mask := Mask}, _Addr) when Mask =/= <<0:32>> -> Mask;
mask(_, Addr) -> classful_mask(Addr).

%% Under a mask shorter than /31, a host holds neither the network nor the broadcast address.
on_subnet_host(<<A:32>>, <<M:32>>) when (bnot M band 16#ffffffff) >= 3 ->
    Host = A band (bnot M) band 16#ffffffff,
    Host =/= 0 andalso Host =/= bnot M band 16#ffffffff;
on_subnet_host(_, _) ->
    true.

%% A router the client can reach on its subnet: a host address, not its own, not the
%% subnet's broadcast.
router(Router, Addr, <<M:32>> = Mask) ->
    <<R:32>> = Router,
    <<A:32>> = Addr,
    host_address(Router) andalso Router =/= Addr andalso R band M =:= A band M
        andalso on_subnet_host(Router, Mask).

%% The first N distinct addresses, in order.
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
