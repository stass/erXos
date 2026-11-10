%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net).
-moduledoc """
The stack's face towards its clients (docs/design-network-stack.md, "Running on a
development host", "Addresses and routes"):

* `local_grant/0` is what `erx_net_client`'s `grant` key names on a node that runs the
  stack itself, `{erx_net, local_grant, []}`;
* `interfaces/0` is the read path of netadmin's view of the interfaces, which `ifconfig`
  shows and the resolver reads its name servers from: each interface's own `status`
  answer (erx_net_if_core), in `inet`'s address forms. Each interface answers for itself,
  so an answer is one interface's state at one moment, and no reader depends on how the
  stack's tables lay out their rows. An interface that ends while it is asked is left
  out, since it no longer exists.
""".

-export([local_grant/0, interfaces/0]).

-export_type([interface/0]).

-doc """
One interface as `interfaces/0` answers it: its name, link-layer address and MTU; its
link state; whether its IPv4 configuration is static or from DHCP; its addresses, each
with its prefix length and, for IPv4, its subnet's broadcast address; its routes, each
with its gateway or `none` for a route on the link; and its lease's name servers and
search list, empty without a lease.
""".
-type interface() :: #{name := term(), lladdr := <<_:48>>, mtu := pos_integer(),
                       link := up | down, config := static | dhcp,
                       addrs := [#{addr := inet:ip_address(), plen := 0..128,
                                   broadcast => inet:ip4_address()}],
                       routes := [#{prefix := inet:ip_address(), plen := 0..128,
                                    gateway := inet:ip_address() | none}],
                       dns := [inet:ip4_address()], search := [binary()]}.

-doc "The node's own grant, `local`, which erx_net_sup started; its messages arrive bare, from the origin `local`.".
-spec local_grant() -> {ok, pid(), local} | {error, enotconn}.
local_grant() ->
    case whereis(erx_net_grant) of
        undefined -> {error, enotconn};
        Pid -> {ok, Pid, local}
    end.

-doc "Every interface, in the order of their names; `enotconn` when the stack is not running.".
-spec interfaces() -> {ok, [interface()]} | {error, enotconn}.
interfaces() ->
    case whereis(erx_net_tables) of
        undefined ->
            {error, enotconn};
        _ ->
            {ok, [public(Status) || {_Name, Pid} <- lists:sort(erx_net_tables:interfaces()),
                                    {ok, Status} <- [status(Pid)]]}
    end.

%% The interface's answer, or `gone` when it ended before it answered, however it ended:
%% no exit of an interface reaches the caller.
status(Pid) ->
    try
        erx_net_if:admin(Pid, status)
    catch
        exit:_ ->
            gone
    end.

public(#{addrs := Addrs, routes := Routes, dns := Dns} = Status) ->
    Status#{addrs := [public_addr(Row) || Row <- Addrs],
            routes := [#{prefix => address(Prefix), plen => Plen, gateway => address(Gateway)}
                       || #{prefix := Prefix, plen := Plen, gateway := Gateway} <- Routes],
            dns := [address(Server) || Server <- Dns]}.

public_addr(#{addr := Addr, plen := Plen} = Row) ->
    Public = #{addr => address(Addr), plen => Plen},
    case Row of
        #{broadcast := Broadcast} -> Public#{broadcast => address(Broadcast)};
        #{} -> Public
    end.

address(<<A, B, C, D>>) -> {A, B, C, D};
address(<<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>) -> {A, B, C, D, E, F, G, H};
address(none) -> none.
