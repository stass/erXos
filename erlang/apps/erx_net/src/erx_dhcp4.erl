%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dhcp4).
-moduledoc """
The DHCP client process of one interface (docs/design-network-stack.md, "Addresses and
routes", "The driver"): the effect layer around erx_dhcp4_core. It starts after its
interface, under their link supervisor, takes the interface's link-layer address and MTU
from the interface's published row, and attaches to it with `{dhcp_attach, self()}`.

It passes on to the core only replies whose transaction id is the core's (`xid/1`), which
the core checks again; sends each action to the interface as `{dhcp, self(), Action}`, where the
interface frames messages and configures leases; and arms the clock at the core's
deadline, which the core keeps in milliseconds.

A link that comes up after it went down starts the client again with a fresh core, from
INIT: the core has no INIT-REBOOT yet, so the interface keeps the old lease until the new
one's `configure` replaces it.
""".

-behaviour(gen_server).

-include("erx_dhcp4_wire.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {iface :: pid(),
                lladdr :: <<_:48>>,
                mtu :: pos_integer(),
                core :: erx_dhcp4_core:core(),
                link = up :: up | down,
                armed = infinity :: erx_net_clock:armed()}).

-doc "Starts the client of interface `Name`, which must have published its row.".
-spec start_link(term()) -> {ok, pid()} | {error, term()}.
start_link(Name) ->
    gen_server:start_link(?MODULE, Name, []).

-doc false.
init(Name) ->
    {ok, #{pid := If, lladdr := Lladdr, mtu := Mtu}} = erx_net_tables:interface(Name),
    If ! {dhcp_attach, self()},
    S = #state{iface = If, lladdr = Lladdr, mtu = Mtu, core = fresh(Lladdr, Mtu)},
    {ok, arm(S)}.

-doc false.
handle_call(_Request, _From, S) ->
    {reply, {error, enotsup}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({erx_net_if, {reply, #dhcp4{xid = Xid} = Msg}}, #state{core = Core} = S) ->
    case erx_dhcp4_core:xid(Core) of
        Xid -> {noreply, arm(step({reply, Msg}, S))};
        _ -> {noreply, S}
    end;
handle_info({erx_net_if, {link, up}}, #state{link = down, lladdr = Lladdr, mtu = Mtu} = S) ->
    {noreply, arm(S#state{link = up, core = fresh(Lladdr, Mtu)})};
handle_info({erx_net_if, {link, State}}, S) ->
    {noreply, S#state{link = State}};
handle_info({erx_net_clock, hint}, S) ->
    %% The core ignores a timeout before its deadline, so a stale hint changes nothing.
    {noreply, arm(step(timeout, S#state{armed = infinity}))};
handle_info(_Msg, S) ->
    {noreply, S}.

fresh(Lladdr, Mtu) ->
    Gen = erx_net_rand:new(erx_net_clock:entropy(16)),
    erx_dhcp4_core:new(Lladdr, Mtu, Gen, now_ms()).

step(Event, #state{iface = If, core = Core0} = S) ->
    {Core, Actions} = erx_dhcp4_core:step(Event, Core0, now_ms()),
    [If ! {dhcp, self(), Action} || Action <- Actions],
    S#state{core = Core}.

arm(#state{core = Core, armed = Armed} = S) ->
    Next = case erx_dhcp4_core:next_deadline(Core) of
               infinity -> infinity;
               Ms -> Ms * 1000
           end,
    S#state{armed = erx_net_clock:arm_by(Next, Armed)}.

now_ms() ->
    erx_net_clock:now() div 1000.
