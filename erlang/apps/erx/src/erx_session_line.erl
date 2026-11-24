%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_line).
-moduledoc """
A session's line to a front-end domain (docs/design-system.md, "A session's
lines"): the line process, which is the mint of the line's facet and the
service behind it, erx_web_line's for the web domain and erx_tty_line's for
the SSH domain. This module owns who reaches the line from another domain;
the callback module owns what the line does with a request its facet
forwarded and with its own domain's messages.

Of messages from another domain the line process acts on one alone: the
system domain's mint request, {erx_facet_mint, Tag, Name, Grantee, Principal,
Limits} in the system domain's envelope, for the line's own Name, a Grantee
other than the system domain, and Limits naming the opening, the process of
the system domain that asked for the line. It answers in three strict steps:
it ends the facet it holds, if any, and takes that facet's 'DOWN'; it starts
the new facet with erx_facet:start/3, bound to Grantee, within Limits, and
ending with the session's connection to Grantee, with the line process and
with the opening; and it replies with erx_facet:minted/2, {ok, Facet} or the
start's refusal, after which it holds no facet until the next request. So a
line has one facet at a time, and a newer grant replaces the older one.
Every other message in an envelope is dropped, so the line process is no
door beside its facet.

This module is also the callback of the line's facet. Its admit/3 forwards
each request the facet admitted to the line process with the grantee, the
grantee's caller and the facet, which the facet gives it and the request
never does, and the line hands them to the callback's request/4. A forward
that a facet sent before it ended still runs, and its reply is lost with
that facet's alias. The grant lists no operations, so the facet has no
operation/1 and forwards every request, and the callback answers one of no
operation the line serves {error, badarg}. The line's interfaces name no
message in no call's shape, so the facet has no message/2 and drops such a
message, counted.

Every message without an envelope but a forward is one of the session's own
domain and goes to the callback's info/2, the 'EXIT' of a linked process
among them, since the line traps exits; the parent's 'EXIT' ends the line.
""".

-behaviour(erx_facet).

-export([start_link/2]).
-export([line_init/3]).
-export([init/1, admit/3]).

-export_type([config/0, forward/0]).

-doc """
The callback's state for the line's Config, before the line serves anyone.
Config holds the line's own keys and the callback's.
""".
-callback init(Config :: config()) -> State :: term().

-doc """
A request of the grantee's that the line's facet admitted and forwarded:
Forward names the grantee, its caller and the facet. The callback answers
From and returns its next state.
""".
-callback request(From :: gen_server:from(), Request :: term(), Forward :: forward(), State :: term()) ->
    NextState :: term().

-doc """
A message of the session's own domain; the callback takes its own shapes and
returns its next state.
""".
-callback info(Message :: term(), State :: term()) -> NextState :: term().

%% name is the line's name among ?ERX_LINES, which the mint request names, system the
%% system domain's id, exports the export table (erx_dist or a host test's stand-in) and
%% connection the session's connection to a domain (erx_connections:connection/1 or a
%% host test's stand-in). The callback's own keys ride beside them.
-type config() :: #{name := atom(), system => pos_integer(), exports => module(),
                    connection => fun((pos_integer()) -> {ok, pid() | port()} | {error, term()}),
                    atom() => term()}.

%% What a forward names besides the request: the grantee, the grantee's caller and the
%% facet the request came through.
-type forward() :: #{grantee := pos_integer(), caller := pid(), facet := pid()}.

-doc "Starts the line of callback Module for Config, linked to the caller.".
-spec start_link(module(), config()) -> {ok, pid()}.
start_link(Module, #{name := Name} = Config) when is_atom(Module), is_atom(Name) ->
    Defaults = #{exports => erx_dist, connection => fun erx_connections:connection/1},
    proc_lib:start_link(?MODULE, line_init, [self(), Module, maps:merge(Defaults, Config)]).

-doc false.
line_init(Parent, Module, Config) ->
    process_flag(trap_exit, true),
    %% ps names the line after its callback module, as a gen_server's process is named.
    put('$initial_call', {Module, init, 1}),
    System = case Config of
                 #{system := Id} -> Id;
                 #{} -> erx_kernel_records:system_domain()
             end,
    Full = Config#{system => System},
    State = Module:init(Full),
    proc_lib:init_ack(Parent, {ok, self()}),
    line(Parent, Module, (maps:with([name, system, exports, connection], Full))#{facet => none}, State).

%% The line's state: its config's own keys, and the facet it holds with the monitor
%% through which it hears that facet's end, or none.
line(Parent, Module, #{name := Name, system := System, facet := Held} = Line, State) ->
    receive
        {erx_origin, System, {erx_facet_mint, Tag, Name, Grantee, _Principal, #{opening := Opening} = Limits}}
          when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, Grantee =/= System,
               is_pid(Opening) ->
            line(Parent, Module, mint(Tag, Grantee, Limits, Line), State);
        {erx_origin, _Domain, _Message} ->
            line(Parent, Module, Line, State);
        {'$gen_call', {Facet, _Tag} = From, {?MODULE, Grantee, Caller, Facet, Request}}
          when is_integer(Grantee), is_pid(Caller) ->
            Forward = #{grantee => Grantee, caller => Caller, facet => Facet},
            line(Parent, Module, Line, Module:request(From, Request, Forward, State));
        {'DOWN', Monitor, process, Facet, _Reason} when Held =:= {Facet, Monitor} ->
            line(Parent, Module, Line#{facet := none}, State);
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        Message ->
            line(Parent, Module, Line, Module:info(Message, State))
    end.

%% The mint request's three steps: the held facet ends, the new one starts, and the
%% mint replies.
mint(Tag, Grantee, Limits, Line) ->
    {Reply, Next} = start_facet(Grantee, Limits, revoke(Line)),
    _ = erx_facet:minted(Tag, Reply),
    Next.

%% Ends the held facet and takes its 'DOWN', so nothing of its grantee's is admitted
%% after it and no two facets of the line live at once. A facet traps no exits.
revoke(#{facet := none} = Line) ->
    Line;
revoke(#{facet := {Facet, Monitor}} = Line) ->
    exit(Facet, kill),
    receive {'DOWN', Monitor, process, Facet, _Reason} -> ok end,
    Line#{facet := none}.

%% The facet for Grantee within Limits, ending with the session's connection to Grantee,
%% the line process and the opening, and the line holding it; or the refusal, the line
%% holding none.
start_facet(Grantee, #{opening := Opening} = Limits, #{connection := Connection, exports := Exports} = Line) ->
    maybe
        {ok, Conn} ?= Connection(Grantee),
        Grant = Limits#{grantee => Grantee, ends_with => [Conn, self(), Opening], line => self()},
        {ok, Facet} ?= erx_facet:start(?MODULE, Grant, #{exports => Exports}),
        {{ok, Facet}, Line#{facet := {Facet, erlang:monitor(process, Facet)}}}
    else
        Refusal -> {Refusal, Line}
    end.

%%% The line's facet.

-doc false.
init(#{line := Line, grantee := Grantee}) ->
    {ok, #{line => Line, grantee => Grantee}}.

%% Every request the facet admitted goes to the line process with what the facet
%% knows of it.
-doc false.
admit(Request, Caller, #{line := Line, grantee := Grantee} = State) ->
    {forward, Line, {?MODULE, Grantee, Caller, self(), Request}, State}.
