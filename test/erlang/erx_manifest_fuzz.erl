%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The Erlang reader's verdicts on a corpus of system manifests, for the differential
%% fuzz target of erx_manifest (tools/fuzz/erx_manifest.rb), which compares them line by
%% line with the C reader's (tools/fuzz/manifest_verdicts.c). The corpus file holds
%% records of a 32-bit big-endian length and that many bytes. For each record this prints
%% "ok" when erx_manifest:fuzz/1 accepts it and "error REASON FIELD" when it refuses it.
%% A manifest it accepts has every row of every table fetched and folded, and a fetch past
%% a table's end refused; an exception anywhere is a reader bug, never bad input.

-module(erx_manifest_fuzz).
-export([run/1]).

-define(M, erx_manifest).
%% The tables of the system manifest, as abi/erx_abi.txt declares them; a name that is
%% no table fails the run.
-define(TABLES, [principals, domains, sessions, limits, runtime_limits, lane_classes, units, devices,
                 windows, services, facets, facet_operations, facet_parameters, introductions,
                 images, extents, boot_order, liveness, shell_principals, partial_boot,
                 starts]).

run([Corpus]) ->
    {ok, Bytes} = file:read_file(Corpus),
    Lines = records(Bytes, []),
    ok = file:write_file("erlang-verdicts.txt", Lines),
    io:format("fuzz: ~p manifests read~n", [length(Lines)]).

records(<<>>, Lines) ->
    lists:reverse(Lines);
records(<<Length:32, Record:Length/binary, Rest/binary>>, Lines) ->
    records(Rest, [verdict(Record) | Lines]).

verdict(Record) ->
    case ?M:fuzz(Record) of
        {ok, View} ->
            {ok, _} = ?M:header(View),
            lists:foreach(fun(Table) -> rows(View, Table) end, ?TABLES),
            <<"ok\n">>;
        {error, #{reason := Reason, field := Field, offset := Offset}}
          when is_atom(Reason), is_binary(Field), is_integer(Offset) ->
            <<"error ", (atom_to_binary(Reason))/binary, " ", Field/binary, "\n">>
    end.

%% Every row of Table fetches, the fold visits each once, and the row past the end is refused.
rows(View, Table) ->
    {ok, Count} = ?M:count(View, Table),
    lists:foreach(fun(Index) -> {ok, #{}} = ?M:fetch(View, Table, Index) end,
                  lists:seq(0, Count - 1)),
    {ok, Count} = ?M:fold(View, Table, fun(#{}, N) -> N + 1 end, 0),
    {error, #{reason := index}} = ?M:fetch(View, Table, Count).
