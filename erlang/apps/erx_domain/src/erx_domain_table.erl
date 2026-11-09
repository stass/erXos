%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_table).
-moduledoc """
The holder of the domain service's table (docs/design-system.md, "System
services"). It makes the table and gives it to the service that claims it,
with itself as heir, so the table comes back here when the service ends and
goes to the next service that claims it. The table is private: only the
service that holds it reads or writes it, so no other process sees the refs
its domain pids answer to.
""".
-behaviour(gen_server).

-export([start_link/0, claim/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Gives the caller the table: {ok, Table}, or {error, held} while another service holds it.".
-spec claim() -> {ok, ets:tid()} | {error, held}.
claim() ->
    gen_server:call(?MODULE, claim).

init([]) ->
    {ok, ets:new(erx_domains, [set, private])}.

handle_call(claim, {Pid, _}, Table) ->
    case ets:info(Table, owner) =:= self() of
        true ->
            true = ets:setopts(Table, {heir, self(), none}),
            true = ets:give_away(Table, Pid, none),
            {reply, {ok, Table}, Table};
        false ->
            {reply, {error, held}, Table}
    end.

handle_cast(_Request, Table) ->
    {noreply, Table}.

handle_info(_Message, Table) ->
    {noreply, Table}.
