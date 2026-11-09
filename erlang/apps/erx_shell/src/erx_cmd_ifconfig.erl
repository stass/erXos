%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ifconfig).
-moduledoc """
`ifconfig [-a] [interface]`: writes the network interfaces' state as FreeBSD's ifconfig
does (sbin/ifconfig), every interface without an operand or under `-a`, and the one
named otherwise. It shows and changes nothing else: any further operand, an address or
a parameter to set, is a usage error, since interfaces are configured by the network
domain's configuration and DHCP, not from the shell.

The state comes from the stack's read path, erx_net:interfaces/0, each interface's own
answer; the command reads no table of the stack. Each interface is written in FreeBSD's
layout and order, one tab before each line after the first:

    vtnet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
    	ether 52:54:00:12:34:56
    	inet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255
    	status: active

The flags are those of an Ethernet interface the stack drives (`if_ethersubr.c` sets
BROADCAST, SIMPLEX and MULTICAST; the interface is administratively up and its driver
running), with LOWER_UP while the link is up, as FreeBSD 15 shows it; the status is
`active` or `no carrier`. A line FreeBSD writes from state the stack does not keep
(`options`, `media`, `nd6`, a metric other than 0) is left out, never made up. An
interface name is written through the field escape (erx_text:escape_field/1), although
the stack's names are its own.

A name no interface has is reported as FreeBSD reports it, `ifconfig: interface NAME does
not exist`, with status 1; a stack that is not running is reported as `ifconfig: network
stack: ...`, with status 1.

The selection and the layout are a pure core, select/2, flags/1 and interface/1, which
the tests drive directly; run/2 asks the stack and writes the lines.
""".

-behaviour(erx_cmd).
-erx_command(ifconfig).
-erx_usage("ifconfig [-a] [interface]").

-export([run/2]).
-export([select/2, flags/1, interface/1]).

%% FreeBSD's flag bits (net/if.h) and names (sbin/ifconfig/ifconfig.c IFFBITS), in bit order.
-define(FLAG_BITS, [{up, 16#1, <<"UP">>}, {broadcast, 16#2, <<"BROADCAST">>},
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
    case erx_net:interfaces() of
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
-spec select([binary()], [erx_net:interface()]) ->
          {ok, [erx_net:interface()]} | {error, {no_interface, binary()}}.
select([], Interfaces) ->
    {ok, Interfaces};
select([Name], Interfaces) ->
    case [I || #{name := N} = I <- Interfaces, name(N) =:= Name] of
        [] -> {error, {no_interface, Name}};
        Found -> {ok, Found}
    end.

-doc "The flags of an interface, by name in FreeBSD's bit order.".
-spec flags(erx_net:interface()) -> [atom()].
flags(#{link := Link}) ->
    [up, broadcast, running, simplex, multicast] ++ [lower_up || Link =:= up].

-doc "The lines ifconfig writes for one interface.".
-spec interface(erx_net:interface()) -> iodata().
interface(#{name := Name, lladdr := Lladdr, mtu := Mtu, link := Link, addrs := Addrs} = I) ->
    Flags = flags(I),
    Bits = lists:sum([Bit || {Flag, Bit, _} <- ?FLAG_BITS, lists:member(Flag, Flags)]),
    Names = [Text || {Flag, _, Text} <- ?FLAG_BITS, lists:member(Flag, Flags)],
    [erx_text:escape_field(name(Name)), <<": flags=">>, hex(Bits, 1), $<,
     lists:join($,, Names), <<"> metric 0 mtu ">>, integer_to_binary(Mtu), $\n,
     <<"\tether ">>, ether(Lladdr), $\n,
     [inet(A) || #{addr := {_, _, _, _}} = A <- Addrs],
     <<"\tstatus: ">>, status(Link), $\n].

name(Name) when is_atom(Name) -> atom_to_binary(Name);
name(Name) when is_binary(Name) -> Name.

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
