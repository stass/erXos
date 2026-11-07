%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_where).
-moduledoc """
`where [-u] predicate ...`: passes on each record of its input whose
predicate (erx_shell_where) is true, in the order and with the fields it
came with; with `-u`, each record the predicate could not decide instead,
so a record with an `unknown` value is neither kept nor coerced. The
arguments are joined by spaces into one predicate, so it can be written
quoted or not. A line of input is a record of one field, `line`.
""".

-behaviour(erx_cmd).
-erx_command(where).
-erx_usage("where [-u] predicate ...").

-export([run/2]).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "u") of
        {ok, Flags, [_ | _] = Words} ->
            case erx_shell_where:parse(iolist_to_binary(lists:join($\s, Words))) of
                {ok, Pred} -> filter(Pred, wanted(Flags), Ctx);
                {error, Message} -> {error, Message}
            end;
        _ -> {error, usage}
    end.

wanted(Flags) ->
    case lists:member($u, Flags) of
        true -> undecided;
        false -> true
    end.

filter(Pred, Wanted, Ctx) ->
    case erx_cmd:read_record(Ctx) of
        eof -> ok;
        {Fields, Record} ->
            case erx_shell_where:eval(Pred, Record) of
                Wanted -> erx_cmd:emit(Ctx, Fields, Record);
                _ -> ok
            end,
            filter(Pred, Wanted, Ctx)
    end.
