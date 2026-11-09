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
(docs/design-network-stack.md, "Ports and the demultiplexing table"). This module holds
their pure part, the choice of an ephemeral port, translated from `in_pcb_lport_dest` of
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
-export([insert/3, insert_ephemeral/4, claim_tcp/5, delete/1]).

-export_type([port_number/0]).

%% IPPORT_EPHEMERALFIRST and IPPORT_EPHEMERALLAST (sys/netinet/in.h).
-define(FIRST_AUTO, 10000).
-define(LAST_AUTO, 65535).

-type port_number() :: ?FIRST_AUTO..?LAST_AUTO.

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

-doc "Removes `Key` from the demultiplexing table.".
-spec delete(erx_net_input:key()) -> ok.
delete(Key) ->
    true = ets:delete(erx_net_demux, Key),
    ok.
