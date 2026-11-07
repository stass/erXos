%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_kernel_records).
-moduledoc """
The collector of erx_object_info (docs/design-live.md, "Inspection
records"): the machine, CPU, group, budget and thread records of the
system domain, each attribute from the report's reported bit and the
partial bit of the system domain's own liberx.

| reported | partial | attribute                                  |
| -------- | ------- | ------------------------------------------ |
| set      | clear   | {kernel, {ok, V}}                          |
| clear    | set     | {{stopgap, S}, {partial, V}}, S the schema's |
| clear    | clear   | {kernel, unsupported}, as for no field      |
| set      | set     | {kernel, {error, invalid}}, liberx's fault  |

A partial bit on an attribute that lists no stopgap is {kernel, {error,
invalid}} too. ERX_ENOTSUP makes every attribute unsupported and any
other refusal makes each {kernel, {error, S}}; in a listing, ERX_ERANGE
ends it and any other refusal ends it short, as partial. A
derived attribute is ok only when all its inputs are; otherwise it is
unsupported when an input is and unknown when none is, under the reporter
of an input that is not ok.

The inspector makes every call itself, on its own capabilities, and the
partial mask is its own liberx's, so nothing a domain says reaches either
mask. The pure core, record/5 and listing/4, takes the answers as data.
""".

-export([machine/0, cpus/0, group/0, budget/0, threads/0, system_domain/0]).
-export([record/5, listing/4]).
-export_type([answer/0]).

-include("generated/erx_abi.hrl").

%% The system domain's id, its node's creation (docs/design-domains.md: no
%% node has a creation below 4): its group, budget and threads are the ones
%% the root can name (docs/design-stopgap.md, "Reporting kernel objects").
-define(SYSTEM_DOMAIN, 4).
%% No machine has more CPUs, and no space more threads, than a listing reads.
-define(MAX_CPUS, 64).
-define(MAX_THREADS, 128).

-type answer() :: {ok, binary()} | {error, integer()}.

-doc "The id of the domain whose group, budget and threads these records describe.".
-spec system_domain() -> non_neg_integer().
system_domain() -> ?SYSTEM_DOMAIN.

%%% Effects: the calls, made on the inspector's own capabilities.

-doc "The machine's record.".
-spec machine() -> erx_schema:record().
machine() ->
    collect(machine, [], ?ERX_CAP_NULL, 0).

-doc "A record for each CPU the kernel lists, partial when the listing stopped short.".
-spec cpus() -> {ok | partial, [erx_schema:record()]}.
cpus() ->
    list(cpu, ?ERX_CAP_NULL, ?MAX_CPUS).

-doc "The system domain's group.".
-spec group() -> erx_schema:record().
group() ->
    collect(group, [domains, ?SYSTEM_DOMAIN, group], ?ERX_CAP_SELF, 0).

-doc "The system domain's budget.".
-spec budget() -> erx_schema:record().
budget() ->
    collect(budget, [domains, ?SYSTEM_DOMAIN, budget], ?ERX_CAP_SELF, 0).

-doc "A record for each thread of the system domain, partial when the listing stopped short.".
-spec threads() -> {ok | partial, [erx_schema:record()]}.
threads() ->
    list(thread, ?ERX_CAP_SELF, ?MAX_THREADS).

collect(Kind, Path, Object, Index) ->
    {ok, Record} = record(Kind, Path, Index, erx_object_info:info(Kind, Object, Index),
                          erx_object_info:partial(Kind)),
    Record.

list(Kind, Object, Max) ->
    listing(Kind, fun(Index) -> erx_object_info:info(Kind, Object, Index) end,
            erx_object_info:partial(Kind), Max).

%%% The pure core.

-doc """
The records of a listing: Call(Index) answers for index 0, 1 and on.
ERX_ERANGE ends it whole, {ok, Records}. Any other refusal, a report that
names no entry, or Max answers ends it short, {partial, Records}, with no
record made for what was not listed. A cpu is listed under [cpus, N], a
thread under the system domain's threads by the id its report carries.
""".
-spec listing(cpu | thread, fun((non_neg_integer()) -> answer()), non_neg_integer(),
              non_neg_integer()) -> {ok | partial, [erx_schema:record()]}.
listing(Kind, Call, Partial, Max) ->
    listing(Kind, Call, Partial, 0, Max, []).

listing(_Kind, _Call, _Partial, Max, Max, Records) ->
    {partial, lists:reverse(Records)};
listing(Kind, Call, Partial, Index, Max, Records) ->
    case Call(Index) of
        {error, ?ERX_ERANGE} ->
            {ok, lists:reverse(Records)};
        {ok, _Bytes} = Answer ->
            case entry(Kind, Index, Answer) of
                {ok, Path, Id} ->
                    {ok, Record} = record(Kind, Path, Id, Answer, Partial),
                    listing(Kind, Call, Partial, Index + 1, Max, [Record | Records]);
                error ->
                    {partial, lists:reverse(Records)}
            end;
        {error, _Status} ->
            {partial, lists:reverse(Records)}
    end.

%% An entry's path and id: a CPU's is its index, a thread's the id its
%% report carries, never the listing's index.
entry(cpu, Index, _Answer) ->
    {ok, [cpus, Index], Index};
entry(thread, _Index, {ok, Bytes}) ->
    case erx_schema:decode_report(thread, Bytes) of
        {ok, _Reported, #{id := Id}} -> {ok, [domains, ?SYSTEM_DOMAIN, threads, Id], Id};
        error -> error
    end.

-doc """
The record of Kind at Path from one answer of erx_object_info and the
topic's partial mask, checked whole by erx_schema:validate_record/1.
""".
-spec record(atom(), [erx_schema:segment()], term(), answer(), non_neg_integer()) ->
          {ok, erx_schema:record()} | {error, atom()}.
record(Kind, Path, Id, Answer, Partial) ->
    {ok, Keys} = erx_schema:attributes(Kind),
    Kernel = [{Key, Declaration} || Key <- Keys,
                                    {ok, Declaration} <- [erx_schema:attribute(Kind, Key)],
                                    lists:member(kernel, maps:get(reporters, Declaration))],
    Direct = maps:from_list([{Key, direct(Kind, Key, Declaration, Answer, Partial)}
                             || {Key, #{derived := []} = Declaration} <- Kernel]),
    Derived = maps:from_list([{Key, derived(Key, Inputs, Direct)}
                              || {Key, #{derived := [_ | _] = Inputs}} <- Kernel]),
    Attrs = maps:map(fun(Key, {Reporter, Value}) -> checked(Kind, Key, Reporter, Value) end,
                     maps:merge(Direct, Derived)),
    erx_schema:validate_record(#{schema => erx_schema:schema(), path => Path, kind => Kind, id => Id,
                                 attrs => Attrs, children => children(Path)}).

%% A record's children are the literals its declaration admits.
children(Path) ->
    case erx_schema:resolve(Path) of
        {ok, #{children := {literals, Literals}}} -> Literals;
        _ -> []
    end.

%% The value erx_schema accepts for the attribute, or {error, invalid}.
checked(Kind, Key, Reporter, Value) ->
    case erx_schema:validate_attr(Kind, Key, Reporter, Value) of
        {ok, Attr} -> Attr;
        {error, _} -> {kernel, {error, invalid}}
    end.

%% An attribute the report carries, from its two bits.
direct(Kind, Key, Declaration, {ok, Bytes}, Partial) ->
    {ok, #{bits := Bits}} = erx_schema:report_layout(Kind),
    case {maps:find(Key, Bits), erx_schema:decode_report(Kind, Bytes)} of
        {_, error} ->
            {kernel, {error, invalid}};
        {error, {ok, _Reported, _Fields}} ->
            {kernel, unsupported};
        {{ok, Bit}, {ok, Reported, Fields}} ->
            status(Reported band Bit =/= 0, Partial band Bit =/= 0, stopgap(Declaration),
                   maps:get(Key, Fields))
    end;
direct(_Kind, _Key, _Declaration, {error, ?ERX_ENOTSUP}, _Partial) ->
    {kernel, unsupported};
direct(_Kind, _Key, _Declaration, {error, Status}, _Partial) ->
    {kernel, {error, status_name(Status)}}.

status(true, false, _Stopgap, Value) -> {kernel, {ok, Value}};
status(false, true, {ok, Stopgap}, Value) -> {Stopgap, {partial, Value}};
status(false, true, none, _Value) -> {kernel, {error, invalid}};
status(false, false, _Stopgap, _Value) -> {kernel, unsupported};
status(true, true, _Stopgap, _Value) -> {kernel, {error, invalid}}.

%% The one stopgap reporter the attribute lists for kernel.
stopgap(#{reporters := Reporters}) ->
    case [Reporter || {stopgap, Name} = Reporter <- Reporters, stands_for_kernel(Name)] of
        [Stopgap] -> {ok, Stopgap};
        _ -> none
    end.

stands_for_kernel(Name) ->
    {ok, #{category := Category}} = erx_schema:stopgap(Name),
    Category =:= kernel.

status_name(Status) ->
    case erx_schema:status_name(Status) of
        {ok, Name} -> Name;
        error -> invalid
    end.

%% A derived attribute: ok only when every input is, else unsupported when
%% an input is and unknown when none is, under a not-ok input's reporter.
derived(Key, Inputs, Direct) ->
    Attrs = [maps:get(Input, Direct, {kernel, unsupported}) || Input <- Inputs],
    case [Attr || {_Reporter, Value} = Attr <- Attrs, not is_ok(Value)] of
        [] ->
            {kernel, {ok, derive(Key, maps:from_list(lists:zip(Inputs, [V || {_, {ok, V}} <- Attrs])))}};
        NotOk ->
            case [Reporter || {Reporter, unsupported} <- NotOk] of
                [Reporter | _] -> {Reporter, unsupported};
                [] -> {element(1, hd(NotOk)), unknown}
            end
    end.

is_ok({ok, _}) -> true;
is_ok(_) -> false.

%% The budget's derived values (docs/design-live.md, "Paths"), none of
%% them an unsigned difference that could wrap.
derive(spending, #{used := Used, carved := Carved, lent := Lent}) ->
    Used + Carved + Lent;
derive(borrowing, #{guarantee := Guarantee} = Inputs) ->
    max(derive(spending, Inputs) - Guarantee, 0);
derive(room, #{cap := Cap} = Inputs) ->
    max(Cap - derive(spending, Inputs), 0);
derive(deficit, #{cap := Cap} = Inputs) ->
    max(derive(spending, Inputs) - Cap, 0);
derive(give_back, #{guarantee := Guarantee, pinned := Pinned} = Inputs) ->
    max(Guarantee + derive(borrowing, Inputs) - Pinned, 0).
