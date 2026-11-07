%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_process_records).
-moduledoc """
The collector of process records (docs/design-live.md, "Inspection" and
"Paths"): `[processes, Pid]` for a process of this runtime, from
`erlang:process_info/2`.

Every attribute is `runtime`'s, since this runtime reports it, except the
process's domain, which the inspector knows by construction from the pid
and the schema marks `service`. Names a runtime reports (registered names,
module and function names, file names) are binaries, never atoms made
from a report. ERTS answers every attribute of a live process, so each is
`ok`, with two exceptions that keep what is known and say what is not:

* `links` and `monitors` hold pids only; a link to a port, a monitor of a
  name or of a port, or a list longer than the schema's bound of 1,000
  makes the value `partial`, of the pids it holds, up to the bound.
* `location` is `{Module, Function, Arity, File, Line}`. Code that
  carries no line table (a preloaded module, a BIF) has no source
  position, and ERTS knows that fully: its location is `ok` with the file
  `<<>>` and the line 0, which mean "no source position", since no real
  position has either. A process with no registered name likewise has
  the registered name `<<>>`.

A name whose UTF-8 is longer than the schema's 255 bytes is
`{error, invalid}`, as erx_schema:validate_record/1 makes every value
outside its type. A process that is gone is no record: the inspector
answers its path as a path that names nothing.

The pure core, record/3, takes ERTS's answer as data.
""".

-export([process/2]).
-export([record/3, info_keys/0]).

%%% Effects: the questions put to this runtime.

-doc "The record of a live process of this runtime, owned by Domain; `none` when it is gone.".
-spec process(pid(), non_neg_integer()) -> {ok, erx_schema:record()} | none.
process(Pid, Domain) when node(Pid) =:= node() ->
    record(Pid, info(Pid), Domain).

%% A pid of this node's name but of another creation, an earlier
%% incarnation's, is not this runtime's: process_info/2 refuses it, and it
%% names no live process here.
info(Pid) ->
    try erlang:process_info(Pid, info_keys())
    catch error:badarg -> undefined
    end.

%%% The pure core.

-doc "The process_info/2 items a record is built from.".
-spec info_keys() -> [atom()].
info_keys() ->
    [status, priority, reductions, current_location, heap_size, stack_size,
     message_queue_len, registered_name, group_leader, trap_exit, links, monitors].

-doc """
The record of Pid from process_info/2's answer for info_keys/0, checked
whole by erx_schema:validate_record/1; `none` for `undefined`, the
answer for a process that is gone.
""".
-spec record(pid(), [{atom(), term()}] | undefined, non_neg_integer()) ->
          {ok, erx_schema:record()} | none.
record(_Pid, undefined, _Domain) ->
    none;
record(Pid, Info, Domain) when is_list(Info) ->
    Runtime = maps:from_list([{attribute(Item), {runtime, value(attribute(Item), Answer)}}
                              || {Item, Answer} <- Info]),
    Attrs = maps:map(fun(Key, {Reporter, Value}) -> checked(Key, Reporter, Value) end,
                     Runtime#{domain => {service, {ok, Domain}}}),
    {ok, _} = erx_schema:validate_record(#{schema => erx_schema:schema(), path => [processes, Pid],
                                           kind => process, id => Pid, attrs => Attrs,
                                           children => []}).

%% The attribute a process_info item gives: the item's own name but for two.
attribute(status) -> state;
attribute(current_location) -> location;
attribute(Item) -> Item.

%% The attribute's value from its item.
value(state, Status) -> {ok, Status};
value(location, {Module, Function, Arity, Where}) -> location(Module, Function, Arity, Where);
value(registered_name, []) -> {ok, <<>>};
value(registered_name, Name) when is_atom(Name) -> {ok, atom_to_binary(Name)};
value(links, Links) -> pids(Links, [Link || Link <- Links, is_pid(Link)]);
value(monitors, Monitors) -> pids(Monitors, [Pid || {process, Pid} <- Monitors, is_pid(Pid)]);
value(_Key, Item) -> {ok, Item}.

location(Module, Function, Arity, Where) ->
    Names = {atom_to_binary(Module), atom_to_binary(Function), Arity},
    case {proplists:get_value(file, Where), proplists:get_value(line, Where)} of
        {File, Line} when is_list(File), is_integer(Line) ->
            {ok, location(Names, unicode:characters_to_binary(File), Line)};
        _ ->
            {ok, location(Names, <<>>, 0)}
    end.

location({Module, Function, Arity}, File, Line) -> {Module, Function, Arity, File, Line}.

%% The pids an item holds: ok when they are all it holds and within the
%% bound, partial otherwise.
pids(Item, Pids) ->
    {ok, {list, pid, Bound}} = erx_schema:type(pids),
    case length(Pids) =:= length(Item) andalso length(Pids) =< Bound of
        true -> {ok, Pids};
        false -> {partial, lists:sublist(Pids, Bound)}
    end.

%% The value erx_schema accepts for the attribute, or {error, invalid}.
checked(Key, Reporter, Value) ->
    case erx_schema:validate_attr(process, Key, Reporter, Value) of
        {ok, Attr} -> Attr;
        {error, _} -> {Reporter, {error, invalid}}
    end.

