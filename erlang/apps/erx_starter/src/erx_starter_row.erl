%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_row).
-moduledoc """
The supervisor of one enabled row (docs/design-apps.md, "Keeping a
session"): the row's keeper is its one permanent child, and its intensity
is the row's, so OTP's supervisor is the restart policy and no other
exists. A session that ends, for any reason, and a start the domain
service refuses, end the keeper, which is started again; more than
`restarts` ends within `period` seconds end this supervisor with
`shutdown`, and the row is down (erx_starter_sup).
""".
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).
-export_type([row/0]).

%% What a row's supervisor keeps: the principal's number, the start map its
%% keeper hands the domain service, and the intensity.
-type row() :: #{principal := pos_integer(), start := map(),
                 restarts := non_neg_integer(), period := pos_integer()}.

-spec start_link(row()) -> supervisor:startlink_ret().
start_link(Row) ->
    supervisor:start_link(?MODULE, Row).

init(#{principal := Principal, start := Start, restarts := Restarts, period := Period}) ->
    Keeper = #{id => keeper, start => {erx_starter_keeper, start_link, [Principal, Start]},
               restart => permanent, shutdown => 5000},
    {ok, {#{strategy => one_for_one, intensity => Restarts, period => Period}, [Keeper]}}.
