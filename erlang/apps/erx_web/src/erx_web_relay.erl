%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_relay).

-moduledoc """
The web domain's end of the host link's `web` facet (docs/design-web.md,
"The host tool's front end"): the service `web`, which the manifest grants
the system domain alone, through which the system domain relays the browser
connections `tools/erx web` carries. Each connection is a process of its own
(erx_web_relay_conn) around the connection core erx_web_conn.

This process is the service's mint and the service behind its facet. As the
mint (erx_facet:provide/2) it starts a facet for a mint request in the system
domain's envelope that names the system domain as the grantee, and refuses
any other (erx_driver_ctl:mint_request/3). The facet (init/1, admit/3) takes
the system domain's three requests and forwards each here with its caller,
the system domain's process that relays for one host session, which is the
connection's sink:

* `{connect, C, Line}` starts connection `C` of that sink, bound to `Line`,
  the principal and build its `welcome` reports; at most ?CONNECTIONS of one
  sink at once, the host tool's own bound, past which it is `{error, busy}`,
  and a number the sink has open, or a line the core refuses, is
  `{error, badarg}`;
* `{data, C, Bytes}` hands the connection one whole binary message, or is
  `{error, closed}` for a connection that is not open;
* `{close, C}` ends the connection, which sends nothing more; closing one
  that is not open is `ok`, since its end may be on its way.

A connection is keyed by its sink and number, so two host sessions, one
ending as the next starts, never share a connection. A connection ends with
its sink: it monitors the sink, which a host session's end ends. Connections
are linked to this process, which traps exits, so none outlives it and the
end of one leaves the table.

What a connection may hold is the core's bound (W8); what this process holds
is one table entry per open connection.
""".

-behaviour(erx_facet).

-export([start_link/1]).
-export([init/1, admit/3]).
-export([relay_init/2]).

-export_type([line/0]).

%% The principal and build a connection's `welcome` reports, as the system
%% domain binds the host's connections.
-type line() :: #{principal := binary(), build := binary()}.
-type config() :: #{system := pos_integer()}.

%% The connections one sink may hold at once: the host tool's own bound on its
%% WebSockets.
-define(CONNECTIONS, 4).
-define(IS_NUMBER(C), (is_integer(C) andalso C >= 0 andalso C =< 16#FFFFFFFF)).

-record(relay, {parent :: pid(),
                config :: config(),
                %% Each open connection's process by its sink and number, and back.
                conns = #{} :: #{{pid(), non_neg_integer()} => pid()},
                keys = #{} :: #{pid() => {pid(), non_neg_integer()}}}).

-doc """
Starts the relay, linked to the caller, a supervisor of the web domain's:
start it while the web application starts, before init's ready report
(erx_facet:provide/2). `system` is the system domain's id.
""".
-spec start_link(config()) -> {ok, pid()}.
start_link(#{system := System} = Config) when is_integer(System), System > 0 ->
    proc_lib:start_link(?MODULE, relay_init, [self(), Config]).

-doc false.
relay_init(Parent, Config) ->
    process_flag(trap_exit, true),
    ok = erx_facet:provide(web, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(#relay{parent = Parent, config = Config}).

loop(#relay{parent = Parent, config = #{system := System}} = Relay) ->
    receive
        {'$gen_call', From, Request} ->
            {Reply, Next} = request(Request, Relay),
            gen_server:reply(From, Reply),
            loop(Next);
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        {'EXIT', Conn, _Reason} ->
            loop(forget(Conn, Relay));
        Message ->
            _ = case erx_driver_ctl:mint_request(System, web, Message) of
                    {grant, Tag, Limits} ->
                        Grant = Limits#{grantee => System, ends_with => [self()], relay => self()},
                        erx_facet:minted(Tag, erx_facet:start(?MODULE, Grant, #{}));
                    {refuse, Tag} ->
                        erx_facet:minted(Tag, {error, eperm});
                    unknown ->
                        ok
                end,
            loop(Relay)
    end.

%% A request the facet forwarded, with the sink it came from.
request({connect, Sink, C, Line}, #relay{conns = Conns} = Relay) ->
    Held = length([Key || {S, _} = Key <- maps:keys(Conns), S =:= Sink]),
    if
        is_map_key({Sink, C}, Conns) ->
            {{error, badarg}, Relay};
        Held >= ?CONNECTIONS ->
            {{error, busy}, Relay};
        true ->
            case erx_web_relay_conn:start_link(Sink, C, Line) of
                {ok, Conn} -> {ok, remember({Sink, C}, Conn, Relay)};
                {error, _} -> {{error, badarg}, Relay}
            end
    end;
request({data, Sink, C, Bytes}, #relay{conns = Conns} = Relay) ->
    case Conns of
        #{{Sink, C} := Conn} ->
            Conn ! {in, Bytes},
            {ok, Relay};
        #{} ->
            {{error, closed}, Relay}
    end;
request({close, Sink, C}, #relay{conns = Conns} = Relay) ->
    case Conns of
        #{{Sink, C} := Conn} ->
            Conn ! close,
            {ok, forget(Conn, Relay)};
        #{} ->
            {ok, Relay}
    end;
request(_Request, Relay) ->
    {{error, badarg}, Relay}.

remember(Key, Conn, #relay{conns = Conns, keys = Keys} = Relay) ->
    Relay#relay{conns = Conns#{Key => Conn}, keys = Keys#{Conn => Key}}.

forget(Conn, #relay{conns = Conns, keys = Keys} = Relay) ->
    case maps:take(Conn, Keys) of
        {Key, Rest} -> Relay#relay{conns = maps:remove(Key, Conns), keys = Rest};
        error -> Relay
    end.

%%% The facet the mint starts for the system domain.

-doc false.
init(#{relay := Relay}) ->
    {ok, Relay}.

-doc """
What the facet does with a request of the system domain's process `Sink`:
each of the three shapes is forwarded to the relay with the sink; any other
is refused.
""".
admit({connect, C, #{principal := Principal, build := Build} = Line}, Sink, Relay)
  when ?IS_NUMBER(C), is_binary(Principal), is_binary(Build) ->
    {forward, Relay, {connect, Sink, C, Line}, Relay};
admit({data, C, Bytes}, Sink, Relay) when ?IS_NUMBER(C), is_binary(Bytes) ->
    {forward, Relay, {data, Sink, C, Bytes}, Relay};
admit({close, C}, Sink, Relay) when ?IS_NUMBER(C) ->
    {forward, Relay, {close, Sink, C}, Relay};
admit(_Request, _Sink, Relay) ->
    {refuse, badarg, Relay}.
