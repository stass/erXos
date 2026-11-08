%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_runtime_records).
-moduledoc """
The collector of a domain's record (docs/design-live.md, "Inspection"):
`[domains, D]` for the domain this runtime runs, its runtime attributes
from this runtime's own counters.

Each runtime attribute is reported by `runtime` and is `ok`, since ERTS
counts it exactly: its atoms, ETS tables, loaded modules and processes,
and its run queue, the processes and ports ready to run and waiting in
the normal and dirty CPU run queues (erlang:statistics(run_queue)), an
instant's count and never a load average. The domain service's attributes (name, principal, state) and the
kernel's thread count have no collector here and are `unsupported` under
their own reporters, so the record never shows a value nobody reported.

The pure core, domain/2, takes the runtime's counters as data.
""".

-export([domain/1]).
-export([domain/2]).
-export_type([figures/0]).

%% This runtime's counters, one per runtime attribute of a domain record.
-type figures() :: #{atoms := non_neg_integer(), ets_tables := non_neg_integer(),
                     modules := non_neg_integer(), processes := non_neg_integer(),
                     run_queue := non_neg_integer()}.

-doc "The record of Domain, the domain this runtime runs, from this runtime's counters.".
-spec domain(non_neg_integer()) -> {ok, erx_schema:record()}.
domain(Domain) ->
    domain(Domain, #{atoms => erlang:system_info(atom_count),
                     ets_tables => length(ets:all()),
                     modules => length(code:all_loaded()),
                     processes => erlang:system_info(process_count),
                     run_queue => erlang:statistics(run_queue)}).

-doc """
The record of Domain from a runtime's counters: each runtime attribute
`ok` from them, every other attribute `unsupported` under its first
reporter, checked whole by erx_schema:validate_record/1.
""".
-spec domain(non_neg_integer(), figures()) -> {ok, erx_schema:record()}.
domain(Domain, Figures) ->
    Path = [domains, Domain],
    {ok, Keys} = erx_schema:attributes(domain),
    Attrs = maps:from_list([{Key, attribute(Key, Figures)} || Key <- Keys]),
    {ok, _} = erx_schema:validate_record(#{schema => erx_schema:schema(), path => Path,
                                           kind => domain, id => Domain, attrs => Attrs,
                                           children => children(erx_schema:resolve(Path))}).

%% A record's children are the literals its declaration admits.
children({ok, #{children := {literals, Literals}}}) -> Literals;
children(_Declaration) -> [].

%% An attribute this runtime counts, or one it has no collector for: a
%% runtime attribute the counters lack is unsupported too.
attribute(Key, Figures) ->
    {ok, #{reporters := [Reporter | _]}} = erx_schema:attribute(domain, Key),
    case Figures of
        #{Key := Count} when Reporter =:= runtime -> {runtime, {ok, Count}};
        #{} -> {Reporter, unsupported}
    end.
