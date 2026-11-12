%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_process_records).
-moduledoc """
The collector of process records (docs/design-live.md, "Inspection" and
"Paths"): `[processes, P]` for a process of this runtime, from
`erlang:process_info/2`.

Every attribute is `runtime`'s, since this runtime reports it, except the
process's domain, which the inspector knows by construction from the pid
and the schema marks `service`. Names a runtime reports (registered names,
module and function names, file names) are binaries, never atoms made
from a report. ERTS answers every attribute of a live process, so each is
`ok`, with two exceptions that keep what is known and say what is not:

* `links` and `monitors` hold processes only; a link to a port, a monitor
  of a name or of a port, or a list longer than the schema's bound of
  1,000 makes the value `partial`, of the processes it holds, up to the
  bound.
* `location` is `{Module, Function, Arity, File, Line}`. Code that
  carries no line table (a preloaded module, a BIF) has no source
  position, and ERTS knows that fully: its location is `ok` with the file
  `<<>>` and the line 0, which mean "no source position", since no real
  position has either. A process with no registered name likewise has
  the registered name `<<>>`.

A record names every process, its own path and id, its group leader, its
links and its monitors, by its `proc_id()`, never by its pid
(docs/design-live.md, "Names travel as data"): proc_id/2 turns a live
pid into one and local_pid/2 a `proc_id()` of this runtime back into its
pid, both as the runtime of a domain names its own processes.

A name whose UTF-8 is longer than the schema's 255 bytes is
`{error, invalid}`, as erx_schema:validate_record/1 makes every value
outside its type. A process that is gone is no record: the inspector
answers its path as a path that names nothing.

The pure core, record/3, takes ERTS's answer as data.
""".

-export([process/2]).
-export([record/3, info_keys/0, proc_id/2, local_pid/2]).

%% The external term format's pid tag (erts/doc external_term_format) and
%% the bound of each of its three numbers.
-define(NEW_PID_EXT, 88).
-define(U32, 16#ffffffff).

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
    Runtime = maps:from_list([{attribute(Item), {runtime, value(attribute(Item), Answer, Domain)}}
                              || {Item, Answer} <- Info]),
    Attrs = maps:map(fun(Key, {Reporter, Value}) -> checked(Key, Reporter, Value) end,
                     Runtime#{domain => {service, {ok, Domain}}}),
    Id = proc_id(Pid, Domain),
    {ok, _} = erx_schema:validate_record(#{schema => erx_schema:schema(), path => [processes, Id],
                                           kind => process, id => Id, attrs => Attrs,
                                           children => []}).

-doc """
The `proc_id()` of Pid as the runtime of Domain names it, `{pid, D, N, S}`:
the three numbers of a pid's text `<D.N.S>` (docs/design-domains.md,
"Domain ids, pids and references").

- N and S are the pid's number and serial.
- D is the domain that owns the pid. For a pid of this runtime, this
  node's name and creation, D is Domain.
- For any other pid, D is the creation the pid carries, which is its
  domain's id: a peer domain's pid, or a pid of an earlier run of this
  node, which is not the process of this runtime with the same numbers.

This runtime is special because its creation need not be its domain's
id, as on a host runtime that stands for the system domain (TODO.md,
inspector). The
numbers are read from the pid's external format, NEW_PID_EXT, whose last
12 bytes they are, so they do not depend on how this runtime prints a pid.
""".
-spec proc_id(pid(), non_neg_integer()) -> erx_schema:proc_id().
proc_id(Pid, Domain) ->
    {Number, Serial, Creation} = numbers(Pid),
    case node(Pid) =:= node() andalso Creation =:= erlang:system_info(creation) of
        true -> {pid, Domain, Number, Serial};
        false -> {pid, Creation, Number, Serial}
    end.

-doc """
The pid of this runtime that ProcId names, when ProcId is a process of
Domain, the domain this runtime is; `error` for another domain's, and
for numbers no pid of this runtime has. The pid is decoded, in safe mode,
from this node's name and creation with the numbers, and kept only when
it is a pid of this node that carries the same numbers back, so each
`proc_id()` names at most one pid.
""".
-spec local_pid(erx_schema:proc_id(), non_neg_integer()) -> {ok, pid()} | error.
local_pid({pid, Domain, N, S}, Domain)
  when is_integer(N), N >= 0, N =< ?U32, is_integer(S), S >= 0, S =< ?U32 ->
    <<131, Node/binary>> = term_to_binary(node()),
    Bytes = <<131, ?NEW_PID_EXT, Node/binary, N:32, S:32, (erlang:system_info(creation)):32>>,
    try binary_to_term(Bytes, [safe]) of
        Pid when is_pid(Pid), node(Pid) =:= node() ->
            case numbers(Pid) of
                {N, S, _Creation} -> {ok, Pid};
                _Other -> error
            end;
        _Term ->
            error
    catch
        error:badarg -> error
    end;
local_pid(_ProcId, _Domain) ->
    error.

%% A pid's number, serial and creation: the last 12 bytes of its
%% NEW_PID_EXT, after its node's atom.
numbers(Pid) ->
    <<131, ?NEW_PID_EXT, Rest/binary>> = term_to_binary(Pid),
    <<Number:32, Serial:32, Creation:32>> = binary:part(Rest, byte_size(Rest), -12),
    {Number, Serial, Creation}.

%% The attribute a process_info item gives: the item's own name but for two.
attribute(status) -> state;
attribute(current_location) -> location;
attribute(Item) -> Item.

%% The attribute's value from its item, every process in it by its
%% proc_id() as the runtime of Domain names it.
value(state, Status, _Domain) -> {ok, Status};
value(location, {Module, Function, Arity, Where}, _Domain) -> location(Module, Function, Arity, Where);
value(registered_name, [], _Domain) -> {ok, <<>>};
value(registered_name, Name, _Domain) when is_atom(Name) -> {ok, atom_to_binary(Name)};
value(group_leader, Pid, Domain) when is_pid(Pid) -> {ok, proc_id(Pid, Domain)};
value(links, Links, Domain) -> proc_ids(Links, [Link || Link <- Links, is_pid(Link)], Domain);
value(monitors, Monitors, Domain) ->
    proc_ids(Monitors, [Pid || {process, Pid} <- Monitors, is_pid(Pid)], Domain);
value(_Key, Item, _Domain) -> {ok, Item}.

location(Module, Function, Arity, Where) ->
    Names = {atom_to_binary(Module), atom_to_binary(Function), Arity},
    case {proplists:get_value(file, Where), proplists:get_value(line, Where)} of
        {File, Line} when is_list(File), is_integer(Line) ->
            {ok, location(Names, unicode:characters_to_binary(File), Line)};
        _ ->
            {ok, location(Names, <<>>, 0)}
    end.

location({Module, Function, Arity}, File, Line) -> {Module, Function, Arity, File, Line}.

%% The processes an item holds, by their proc_id(): ok when they are all it
%% holds and within the bound, partial otherwise.
proc_ids(Item, Pids, Domain) ->
    {ok, {list, proc_id, Bound}} = erx_schema:type(proc_ids),
    Ids = [proc_id(Pid, Domain) || Pid <- lists:sublist(Pids, Bound)],
    case length(Pids) =:= length(Item) andalso length(Pids) =< Bound of
        true -> {ok, Ids};
        false -> {partial, Ids}
    end.

%% The value erx_schema accepts for the attribute, or {error, invalid}.
checked(Key, Reporter, Value) ->
    case erx_schema:validate_attr(process, Key, Reporter, Value) of
        {ok, Attr} -> Attr;
        {error, _} -> {Reporter, {error, invalid}}
    end.

