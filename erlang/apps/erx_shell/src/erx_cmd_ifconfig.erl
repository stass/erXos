%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ifconfig).
-moduledoc """
`ifconfig [-a] [interface]`: writes the network interfaces' state as FreeBSD's ifconfig
does (sbin/ifconfig), every interface without an operand or under `-a`, and the one
named otherwise. It shows and changes nothing else: any further operand, an address or
a parameter to set, is a usage error, since interfaces are configured by the network
domain's configuration and DHCP, not from the shell.

The state comes from the domain's grant, its `interfaces` operation through
erx_inet:call/1, which checks the answer (erx_sock_admit); the command calls no module of
the stack and reads none of its tables. Each interface is written in FreeBSD's
layout and order, one tab before each line after the first:

    vtnet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
    	ether 52:54:00:12:34:56
    	inet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255
    	status: active

The loopback interface, the one without a link-layer address, has the flags
`if_loop.c` sets (LOOPBACK, MULTICAST), up and running, with LOWER_UP, which FreeBSD 15's
netlink sets for an interface of no Ethernet type that is up (`iface.c:183-190`, `:312`), and
neither an `ether` nor a `status` line:

    lo0: flags=1008049<UP,LOOPBACK,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 16384
    	inet 127.0.0.1 netmask 0xff000000

The flags of an Ethernet interface are those of the Ethernet interfaces the stack drives
(`if_ethersubr.c` sets BROADCAST, SIMPLEX and MULTICAST; the interface is administratively
up and its driver running), with LOWER_UP while the link is up, as FreeBSD 15 shows it; the status is
`active` or `no carrier`. A line FreeBSD writes from state the stack does not keep
(`options`, `media`, `nd6`, a metric other than 0) is left out, never made up. An
interface name is written through the field escape (erx_text:escape_field/1), although
the stack's names are its own.

A name no interface has is reported as FreeBSD reports it, `ifconfig: interface NAME does
not exist`, with status 1; a grant that does not answer is reported as `ifconfig: network
stack: ...`, with status 1.

The selection and the layout are a pure core, select/2, flags/1 and interface/1, which
the tests drive directly; run/2 asks the stack and writes the lines.
""".

-behaviour(erx_cmd).
-erx_command(ifconfig).
-erx_usage("ifconfig [-a] [interface]").
%% The network stack is a service of the system domain: a session reaches it
%% only through its net facet.
-erx_needs([net]).

-export([run/2]).
-export([select/2, flags/1, interface/1]).

-export_type([interface/0]).

-doc "An interface as the grant's `interfaces` operation answers it, checked.".
-type interface() :: #{name := binary(), lladdr := <<_:48>> | none, mtu := pos_integer(), link := up | down,
                       config := static | dhcp,
                       addrs := [#{addr := inet:ip_address(), plen := 0..128, broadcast => inet:ip4_address()}]}.

%% FreeBSD's flag bits (net/if.h) and names (sbin/ifconfig/ifconfig.c IFFBITS), in bit order.
-define(FLAG_BITS, [{up, 16#1, <<"UP">>}, {broadcast, 16#2, <<"BROADCAST">>},
                    {loopback, 16#8, <<"LOOPBACK">>},
                    {running, 16#40, <<"RUNNING">>}, {simplex, 16#800, <<"SIMPLEX">>},
                    {multicast, 16#8000, <<"MULTICAST">>}, {lower_up, 16#1000000, <<"LOWER_UP">>}]).

%%% The command

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "a") of
        {ok, _Flags, Operands} when length(Operands) =< 1 ->
            show(Operands, Ctx);
        {ok, _Flags, _Operands} ->
            {error, usage};
        {error, usage} ->
            {error, usage}
    end.

show(Operands, Ctx) ->
    case erx_inet:call(interfaces) of
        {ok, Interfaces} ->
            case select(Operands, Interfaces) of
                {ok, Selected} ->
                    erx_cmd:write(Ctx, [interface(I) || I <- Selected]);
                {error, {no_interface, Name}} ->
                    erx_cmd:say(Ctx, [<<"ifconfig: interface ">>, erx_text:escape_field(Name),
                                      <<" does not exist\n">>]),
                    {error, {reported, <<"1">>}}
            end;
        {error, Reason} ->
            erx_cmd:report(Ctx, <<"network stack">>, Reason),
            {error, {reported, <<"1">>}}
    end.

%%% The core

-doc """
The interfaces an operand list selects: every one for none, the one named for a name, or
`no_interface` with the name when none has it.
""".
-spec select([binary()], [interface()]) ->
          {ok, [interface()]} | {error, {no_interface, binary()}}.
select([], Interfaces) ->
    {ok, Interfaces};
select([Name], Interfaces) ->
    case [I || #{name := N} = I <- Interfaces, N =:= Name] of
        [] -> {error, {no_interface, Name}};
        Found -> {ok, Found}
    end.

-doc "The flags of an interface, by name in FreeBSD's bit order.".
-spec flags(interface()) -> [atom()].
flags(#{lladdr := none, link := Link}) ->
    [up, loopback, running, multicast] ++ [lower_up || Link =:= up];
flags(#{link := Link}) ->
    [up, broadcast, running, simplex, multicast] ++ [lower_up || Link =:= up].

-doc "The lines ifconfig writes for one interface.".
-spec interface(interface()) -> iodata().
interface(#{name := Name, lladdr := Lladdr, mtu := Mtu, link := Link, addrs := Addrs} = I) ->
    Flags = flags(I),
    Bits = lists:sum([Bit || {Flag, Bit, _} <- ?FLAG_BITS, lists:member(Flag, Flags)]),
    Names = [Text || {Flag, _, Text} <- ?FLAG_BITS, lists:member(Flag, Flags)],
    [erx_text:escape_field(Name), <<": flags=">>, hex(Bits, 1), $<,
     lists:join($,, Names), <<"> metric 0 mtu ">>, integer_to_binary(Mtu), $\n,
     link_lines(Lladdr, [inet(A) || #{addr := {_, _, _, _}} = A <- Addrs], Link)].

%% An Ethernet interface's address lines between its link-layer address and its media status;
%% the loopback interface has neither, as FreeBSD 15 writes lo0: no AF_LINK address
%% (if_getaddrlen 0, sys/netlink/route/iface.c:320) and no media (looioctl answers
%% SIOCGIFMEDIA with EINVAL, if_loop.c:442, so media_status writes nothing).
link_lines(none, Inet, _Link) ->
    Inet;
link_lines(Lladdr, Inet, Link) ->
    [<<"\tether ">>, ether(Lladdr), $\n, Inet, <<"\tstatus: ">>, status(Link), $\n].

%% ether_ntoa's layout: lower-case hex, two digits each, separated by colons.
ether(Lladdr) ->
    lists:join($:, [hex(Byte, 2) || <<Byte>> <= Lladdr]).

%% in_status: the address, the netmask in hex as `0x%lx` writes it, the broadcast address
%% when there is one.
inet(#{addr := Addr, plen := Plen} = A) ->
    Mask = (16#ffffffff bsl (32 - Plen)) band 16#ffffffff,
    [<<"\tinet ">>, inet:ntoa(Addr), <<" netmask 0x">>, hex(Mask, 1),
     case A of
         #{broadcast := Broadcast} -> [<<" broadcast ">>, inet:ntoa(Broadcast)];
         #{} -> []
     end, $\n].

status(up) -> <<"active">>;
status(down) -> <<"no carrier">>.

%% N in lower-case hex, padded with zeros to at least Width digits, as printf's `%0*x`.
hex(N, Width) ->
    Digits = string:lowercase(integer_to_list(N, 16)),
    lists:duplicate(max(0, Width - length(Digits)), $0) ++ Digits.
