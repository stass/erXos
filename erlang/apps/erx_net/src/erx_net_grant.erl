%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant).
-moduledoc """
A client domain's grant (docs/design-network-stack.md, "The grant's contract", "The
grant"), as far as an active open needs it: the process every `connect` reaches, which
starts the connection linked to itself, with a generator split from its own, and traps
its exit, so a connection's end never ends the grant. The connection answers the connect
caller; when it exits, however it ends, the grant answers that caller `{error, closed}`
too, so a connection that dies before answering leaves no caller waiting. A caller already
answered never sees the second answer: a call's reply alias is gone once its first reply
arrived. A connection's demultiplexing entries are deleted by erx_net_tables, which
watches it in the grant's place.

The request is checked here before anything acts on it, as `erx_net_admit:request/2` will
check it: an IPv4 address and a port as `gen_tcp` gives them, a list of options, a timeout,
and the caller as owner. The limits, the account and the buffer reservations of
`erx_net_grant_core` are not built: the grant admits every well-formed request.
""".

-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_REQUEST, 64).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).
-define(IS_BYTE4(A, B, C, D), (?IS_BYTE(A) andalso ?IS_BYTE(B) andalso ?IS_BYTE(C) andalso ?IS_BYTE(D))).

-doc """
Starts the grant of `Grantee`. The node's own grant, `local`, is registered as
`erx_net_grant`, where erx_net:local_grant/0 finds it.
""".
-spec start_link(local, map()) -> {ok, pid()} | {error, term()}.
start_link(local, Limits) when is_map(Limits) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Limits, []).

-doc false.
init(Limits) ->
    process_flag(trap_exit, true),
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    {ok, #{limits => Limits, gen => erx_net_rand:new(erx_net_clock:entropy(16)), callers => #{}}}.

-doc false.
handle_call({tcp_connect, inet, {A, B, C, D}, Port, Opts, Timeout}, {Owner, _} = From,
            #{gen := Gen0, callers := Callers} = S)
  when ?IS_BYTE4(A, B, C, D), is_integer(Port), Port > 0, Port =< 16#ffff, is_list(Opts),
       Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0) ->
    {Child, Gen} = erx_net_rand:split(Gen0),
    Start = #{owner => Owner, from => From, remote => {<<A, B, C, D>>, Port}, opts => Opts,
              timeout => Timeout, gen => Child},
    case erx_tcp_conn:start_link(Start) of
        {ok, Conn} -> {noreply, S#{gen := Gen, callers := Callers#{Conn => From}}};
        {error, Reason} -> {reply, {error, Reason}, S#{gen := Gen}}
    end;
handle_call(_Request, _From, S) ->
    {reply, {error, badarg}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({'EXIT', Conn, _Reason}, #{callers := Callers0} = S) ->
    case maps:take(Conn, Callers0) of
        {From, Callers} ->
            gen_server:reply(From, {error, closed}),
            {noreply, S#{callers := Callers}};
        error ->
            {noreply, S}
    end;
handle_info(_Msg, S) ->
    {noreply, S}.
