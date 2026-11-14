%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/in_pcb.c
%%
%% Copyright (c) 1982, 1986, 1991, 1993, 1995
%%    The Regents of the University of California.
%% Copyright (c) 2007-2009 Robert N. M. Watson
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% Copyright (c) 2021-2022 Gleb Smirnoff <glebius@FreeBSD.org>
%% All rights reserved.
%%
%% Portions of this software were developed by Robert N. M. Watson under
%% contract to Juniper Networks, Inc.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of the University nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF

-module(erx_net_bind).
-moduledoc """
The port rules of the demultiplexing table's one insertion funnel
(docs/design-network-stack.md, "Ports and the demultiplexing table"): an explicit bind's
check, `avail/2`, translated from `in_pcbbind_avail`; the one rewrite of an entry,
`update/2`, by the key's holder alone; an active open's claim, `claim_tcp/5`; and the
choice of an ephemeral port, translated from `in_pcb_lport_dest` of
FreeBSD's `sys/netinet/in_pcb.c` at commit 975e3605 (erlang/apps/erx_net/NOTICE-freebsd),
with FreeBSD's defaults: the range 10000 to 65535 (`ipport_firstauto`,
`ipport_lastauto`) searched from a random start (`ipport_randomized`, 1).

The binding socket's step draws the search's first port with `ephemeral_start/1` from the
generator in its state and returns it in its bind action; the funnel tries that port with
`ets:insert_new/2`, then each port `next_ephemeral/2` gives, until one is free or it
returns `exhausted`. `insert/3` is that funnel for one key, and `insert_ephemeral/4` the
search; `delete/1` removes a key its holder no longer wants. The ports come in FreeBSD's order: `in_pcb_lport_dest` sets its
cursor to `first + arc4random() % (last - first)` and tries the port after it, wrapping
from `last` to `first`, until it has tried all `last - first + 1` of them. So the first
port tried is uniform over 10001 to 65535, and every port of the range is tried exactly
once.
""".

-export([ephemeral_start/1, next_ephemeral/2]).
-export([insert/3, insert_ephemeral/4, claim_tcp/5, delete/1, avail/2, allowed/2, update/2]).

-export_type([port_number/0, ports/0, bind_request/0]).

%% IPPORT_EPHEMERALFIRST and IPPORT_EPHEMERALLAST (sys/netinet/in.h).
-define(FIRST_AUTO, 10000).
-define(LAST_AUTO, 65535).

-type port_number() :: ?FIRST_AUTO..?LAST_AUTO.

-doc "Ports as inclusive ranges, `[{1024, 65535}]` for the grant's default `ports`.".
-type ports() :: [{1..16#ffff, 1..16#ffff}].

-doc """
An explicit bind's request, as avail/2 checks it: the transport whose keys it meets, the
family, the local address (`any` or one of the machine's, a binary as the keys hold it),
the port, the reuse options, the binding socket's grant, the ports the grant allows this
bind, and the machine's own addresses of the family, which rule 1 checks the address
against.
""".
-type bind_request() :: #{transport := tcp | udp, family := inet | inet6,
                          local := binary() | any, port := 1..16#ffff,
                          reuseaddr := boolean(), reuseport := boolean(), grant := pid(),
                          allowed := ports(), machine := [binary()]}.

-doc "The first port of a search, drawn from the binding socket's generator.".
-spec ephemeral_start(erx_net_rand:gen()) -> {port_number(), erx_net_rand:gen()}.
ephemeral_start(Gen) ->
    {Offset, Gen1} = erx_net_rand:uniform(?LAST_AUTO - ?FIRST_AUTO, Gen),
    {after_port(?FIRST_AUTO + Offset), Gen1}.

-doc "The port to try after `Port` in a search that began at `Start`, or `exhausted`.".
-spec next_ephemeral(port_number(), Start :: port_number()) -> port_number() | exhausted.
next_ephemeral(Port, Start) when ?FIRST_AUTO =< Port, Port =< ?LAST_AUTO,
                                 ?FIRST_AUTO =< Start, Start =< ?LAST_AUTO ->
    case after_port(Port) of
        Start -> exhausted;
        Next -> Next
    end.

after_port(?LAST_AUTO) -> ?FIRST_AUTO;
after_port(Port) -> Port + 1.

-doc """
Inserts `Key` for `Pid` with its entry, unless another socket holds it: `ets:insert_new/2`
decides a race between two binders, so a key has exactly one holder by construction.
""".
-spec insert(erx_net_input:key(), pid(), erx_net_input:entry()) -> ok | {error, eaddrinuse}.
insert(Key, Pid, Entry) ->
    case ets:insert_new(erx_net_demux, {Key, Pid, Entry}) of
        true -> ok;
        false -> {error, eaddrinuse}
    end.

-doc """
Inserts the key `KeyOf(Port)` for the first free port of the search that begins at
`Start`, and answers that port.
""".
-spec insert_ephemeral(fun((port_number()) -> erx_net_input:key()), port_number(), pid(),
                       erx_net_input:entry()) -> {ok, port_number()} | {error, eaddrinuse}.
insert_ephemeral(KeyOf, Start, Pid, Entry) ->
    search(KeyOf, Start, Start, Pid, Entry).

search(KeyOf, Port, Start, Pid, Entry) ->
    case insert(KeyOf(Port), Pid, Entry) of
        ok ->
            {ok, Port};
        {error, eaddrinuse} = Error ->
            case next_ephemeral(Port, Start) of
                exhausted -> Error;
                Next -> search(KeyOf, Next, Start, Pid, Entry)
            end
    end.

-doc """
The claim of an active open: the first free four-tuple of the search from `Start` that
`KeyOf` gives a key for, as `insert_ephemeral/4` finds it, with the connection's initial
sequence number and timestamp offset at `Now` under the stack's secrets, which this funnel
reads and the connection never holds (`tcp_connect` with `in_pcbconnect`'s port choice and
`tcp_new_isn`).
""".
-spec claim_tcp(fun((port_number()) -> erx_net_input:key()), port_number(), pid(),
                erx_net_input:entry(), integer()) ->
          {ok, port_number(), Iss :: erx_tcp_seq:wire(), TsOffset :: erx_tcp_seq:wire()}
          | {error, eaddrinuse}.
claim_tcp(KeyOf, Start, Pid, Entry, Now) ->
    maybe
        {ok, Port} ?= insert_ephemeral(KeyOf, Start, Pid, Entry),
        {tcp, _Family, Local, Port, Remote, RemotePort} = KeyOf(Port),
        {Iss, TsOffset} = (erx_net_tables:tcp_isn())({Local, Port, Remote, RemotePort}, Now),
        {ok, Port, Iss, TsOffset}
    end.

-doc """
Whether an explicit bind may claim its key: `in_pcbbind_avail` (`in_pcb.c:912-998`) for
unicast addresses, as docs/design-network-stack.md, "Explicit binds", gives its five rules.
`Held` is what the demultiplexing table holds; only keys of the request's transport,
family and port take part, so a TCP listener never meets a UDP key and the caller's read
of the table may be wider than the port. In order:

1. an address that is neither `any` nor one of `machine`, the machine's own addresses of
   the request's family, is refused `eaddrnotavail`;
2. a port outside `allowed`, the ports the grant allows this bind (its `ports`, narrowed by
   `listen` for a listener), is refused `eacces`;
3. a key without a remote end (for UDP, any key) that another grant holds, on the same
   address or with either address `any`, is refused `eaddrinuse` whatever the reuse
   options; an entry that names no grant counts as another grant's;
4. without `reuseaddr` and `reuseport`, any key on the same address, or with either `any`,
   connections included, is refused `eaddrinuse`;
5. with either option, a key without a remote end on exactly the same address is refused
   `eaddrinuse`: the table maps a key to one socket, so `reuseport` acts as `reuseaddr`.
""".
-spec avail(bind_request(), [{erx_net_input:key(), pid(), map()}]) ->
          ok | {error, eaddrnotavail | eacces | eaddrinuse}.
avail(#{transport := Transport, family := Family, local := Local, port := Port,
        reuseaddr := ReuseAddr, reuseport := ReusePort, grant := Grant, allowed := Allowed,
        machine := Machine}, Held)
  when (Transport =:= tcp orelse Transport =:= udp), is_integer(Port), Port >= 1, Port =< 16#ffff,
       is_boolean(ReuseAddr), is_boolean(ReusePort), is_list(Allowed), is_list(Machine) ->
    %% Each key of the request's transport, family and port: its local address, whether it
    %% has a remote end, and the grant its entry names.
    Same = [{HeldLocal, Remote, maps:get(grant, Entry, none)}
            || {Key, _Pid, Entry} <- Held, is_map(Entry),
               {T, F, HeldLocal, P, Remote} <- [view(Key)], T =:= Transport, F =:= Family, P =:= Port],
    Reuse = ReuseAddr orelse ReusePort,
    Ours = Local =:= any orelse (is_binary(Local) andalso lists:member(Local, Machine)),
    Allows = allowed(Port, Allowed),
    Conflict = lists:any(fun(H) -> conflicts(H, Transport, Local, Grant, Reuse) end, Same),
    if
        not Ours -> {error, eaddrnotavail};   % 1
        not Allows -> {error, eacces};        % 2
        Conflict -> {error, eaddrinuse};      % 3 to 5
        true -> ok
    end.

%% Rules 3 to 5 for one held key on the request's port.
conflicts({HeldLocal, Remote, HeldGrant}, Transport, Local, Grant, Reuse) ->
    Overlaps = HeldLocal =:= Local orelse HeldLocal =:= any orelse Local =:= any,
    OtherGrant = HeldGrant =:= none orelse HeldGrant =/= Grant,
    Unconnected = Remote =:= unconnected,
    if
        %% 3: another grant's key without a remote end (for UDP, any of its keys).
        (Unconnected orelse Transport =:= udp) andalso OtherGrant andalso Overlaps -> true;
        %% 4: without reuse, any key on an overlapping address, connections included.
        not Reuse andalso Overlaps -> true;
        %% 5: with reuse, a key without a remote end on exactly the same address.
        Reuse andalso Unconnected andalso HeldLocal =:= Local -> true;
        true -> false
    end.

-doc "Whether `Port` lies in one of the inclusive ranges of `Allowed`.".
-spec allowed(1..16#ffff, ports()) -> boolean().
allowed(Port, Allowed) ->
    lists:any(fun({Lo, Hi}) -> is_integer(Lo) andalso is_integer(Hi) andalso Lo =< Port andalso Port =< Hi;
                 (_) -> false
              end, Allowed).

%% A key as an explicit bind's check sees it: its transport, family, local address and
%% port, and whether it has a remote end. Keys of other kinds (ICMP's) take no part.
view({tcp, F, L, P, _, _}) -> {tcp, F, L, P, connected};
view({tcp_listen, F, L, P}) -> {tcp, F, L, P, unconnected};
view({udp, F, L, P, _, _}) -> {udp, F, L, P, connected};
view({udp, F, L, P}) -> {udp, F, L, P, unconnected};
view(_) -> {none, none, none, none, none}.

-doc """
Replaces the entry of `Key` with `Entry`, only while the caller holds the key and the held
entry has `Entry`'s pid, credit and grant: one `ets:select_replace/2`, whose match and
replacement ETS makes one atomic step (`ets.erl:1864-1870`), so a key its grant's end has
deleted is not brought back and a key that has passed to another socket is left as it is
(docs/design-network-stack.md, "Ports and the demultiplexing table"). A listener rewrites
its own entry with it when its options change. Answers `gone` when it replaced nothing.
""".
-spec update(erx_net_input:key(), map()) -> ok | gone.
update(Key, #{pid := Self, credit := Credit, grant := Grant} = Entry) when Self =:= self() ->
    Spec = [{{Key, Self, '$3'},
             [{is_map, '$3'},
              {is_map_key, credit, '$3'}, {is_map_key, grant, '$3'},
              {'=:=', {map_get, credit, '$3'}, {const, Credit}},
              {'=:=', {map_get, grant, '$3'}, {const, Grant}}],
             [{const, {Key, Self, Entry}}]}],
    case ets:select_replace(erx_net_demux, Spec) of
        1 -> ok;
        0 -> gone
    end.

-doc "Removes `Key` from the demultiplexing table.".
-spec delete(erx_net_input:key()) -> ok.
delete(Key) ->
    true = ets:delete(erx_net_demux, Key),
    ok.
