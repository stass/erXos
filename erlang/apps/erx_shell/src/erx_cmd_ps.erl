%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ps).
-moduledoc """
`ps [-mr] [-o keyword[,keyword...]]`: FreeBSD's ps (bin/ps) over the
session's own process table (docs/design-live.md, "The command shell").

The table is the session's Erlang processes; in Phase 1 the session runs
in the system domain, so that is this runtime's processes, and no
inspect facet is needed, as a UNIX user sees their own processes. The
session's programs join the table once programs run in sessions.

Columns are FreeBSD's default, `PID TT STAT TIME COMMAND`, or those `-o`
names, from `pid`, `tt`, `state` (or `stat`), `time`, `pcpu` (or `%cpu`),
`rss`, `comm` and `command` (or `args`); an unknown keyword is reported
as `ps: KEY: keyword not found`, left out, and makes the status 1. Each
column is as wide as its widest value or header, numbers aligned right,
separated by one space, under a header line, as FreeBSD's are.

A value the table does not have prints `-` (SH3): every value of a
process that ended while it was read, and those the runtime does not
measure at all, its CPU time and `%CPU`, and its terminal, which the
session does not name yet. No column shows a number for a value it does
not have, and every row keeps its columns. A process's name is its
registered name, else its proc_lib label, else the function it started
in, written through the field escape (erx_text:escape_field/1), as
FreeBSD writes names through strvis(3), so each row is one line.

Rows come by pid. `-r` orders by `%CPU` and `-m` by `RSS`, largest
first; rows with equal values, or with none, keep the pid order, those
with none after every row with one. At a terminal each line is cut at
its width (erx_cmd:columns/1, 79 when unknown), as FreeBSD cuts the last
column (bin/ps/ps.c).
""".

-behaviour(erx_cmd).
-erx_command(ps).
-erx_usage("ps [-mr] [-o keyword[,keyword...]]").

-export([run/2]).
-export([table/3, order/2, keywords/1]).

-export_type([row/0]).

%% A process's values, each `missing` when the table does not have it.
-type row() :: #{id := [integer()], pid := binary(),
                 tt := binary() | missing, state := binary() | missing,
                 time := binary() | missing, pcpu := number() | missing,
                 rss := non_neg_integer() | missing,
                 comm := binary() | missing, command := binary() | missing}.

-define(DEFAULT, [pid, tt, state, time, command]).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "mro:") of
        {ok, Flags, []} ->
            Lists = [List || {$o, List} <- Flags],
            {Columns, Unknown} = case Lists of
                                     [] -> {?DEFAULT, []};
                                     _ -> keywords(iolist_to_binary(lists:join($,, Lists)))
                                 end,
            [erx_cmd:say(Ctx, [<<"ps: ">>, Key, <<": keyword not found\n">>]) || Key <- Unknown],
            Sort = lists:foldl(fun($r, _) -> pcpu; ($m, _) -> rss; (_, S) -> S end, none, Flags),
            Width = case erx_cmd:isatty(Ctx, stdout) of
                        true -> case erx_cmd:columns(Ctx) of unknown -> 79; W -> W end;
                        false -> infinity
                    end,
            erx_cmd:write(Ctx, table(Columns, order(session_table(), Sort), Width)),
            case Unknown of
                [] -> ok;
                _ -> {error, {reported, <<"1">>}}
            end;
        _ ->
            {error, usage}
    end.

%%% The table

session_table() ->
    [row(Pid) || Pid <- erlang:processes()].

row(Pid) ->
    Info = erlang:process_info(Pid, [registered_name, status, memory]),
    Name = case Info of
               undefined -> missing;
               _ -> escape(name(Pid, proplists:get_value(registered_name, Info)))
           end,
    #{id => pid_numbers(Pid), pid => list_to_binary(pid_to_list(Pid)),
      tt => missing, time => missing, pcpu => missing,
      state => case Info of undefined -> missing; _ -> state(proplists:get_value(status, Info)) end,
      rss => case Info of undefined -> missing; _ -> (proplists:get_value(memory, Info) + 1023) div 1024 end,
      comm => Name, command => Name}.

pid_numbers(Pid) ->
    [list_to_integer(Part) || Part <- string:lexemes(pid_to_list(Pid), "<.>")].

state(Status) when Status =:= running; Status =:= runnable; Status =:= garbage_collecting -> <<"R">>;
state(waiting) -> <<"S">>;
state(suspended) -> <<"T">>;
state(exiting) -> <<"RE">>;
state(_Other) -> missing.

name(_Pid, Name) when is_atom(Name), Name =/= [] -> atom_to_binary(Name);
name(Pid, _None) ->
    case proc_lib:get_label(Pid) of
        undefined -> initial_call(Pid);
        Label when is_binary(Label) -> Label;
        Label when is_atom(Label) -> atom_to_binary(Label);
        Label -> unicode:characters_to_binary(io_lib:format("~0tp", [Label]))
    end.

%% The function a process started in, as c:i/0 names it: proc_lib's own
%% start translated to the function it was given, or `missing` once the
%% process has ended.
initial_call(Pid) ->
    case erlang:process_info(Pid, initial_call) of
        {initial_call, {proc_lib, init_p, 5}} -> mfa(proc_lib:translate_initial_call(Pid));
        {initial_call, Call} -> mfa(Call);
        undefined -> missing
    end.

mfa({Module, Function, Arity}) ->
    iolist_to_binary([atom_to_binary(Module), $:, atom_to_binary(Function), $/, integer_to_binary(Arity)]).

escape(missing) -> missing;
escape(Name) -> erx_text:escape_field(Name).

%%% The pure core

-doc """
The columns a `-o` list names, in order, and the keywords it holds that
name none.
""".
-spec keywords(binary()) -> {[atom()], [binary()]}.
keywords(List) ->
    Found = [{Key, keyword(Key)} || Key <- binary:split(List, [<<",">>, <<" ">>], [global, trim_all])],
    {[Column || {_, Column} <- Found, Column =/= unknown], [Key || {Key, unknown} <- Found]}.

keyword(<<"pid">>) -> pid;
keyword(<<"tt">>) -> tt;
keyword(<<"state">>) -> state;
keyword(<<"stat">>) -> state;
keyword(<<"time">>) -> time;
keyword(<<"pcpu">>) -> pcpu;
keyword(<<"%cpu">>) -> pcpu;
keyword(<<"rss">>) -> rss;
keyword(<<"comm">>) -> comm;
keyword(<<"command">>) -> command;
keyword(<<"args">>) -> command;
keyword(_Other) -> unknown.

-doc """
Rows by pid, or under `pcpu` or `rss` largest first, each set of equal
values, and the rows with none after them, in pid order.
""".
-spec order([row()], none | pcpu | rss) -> [row()].
order(Rows, none) ->
    lists:sort(fun(#{id := A}, #{id := B}) -> A =< B end, Rows);
order(Rows, Key) ->
    ById = order(Rows, none),
    {With, Without} = lists:partition(fun(Row) -> maps:get(Key, Row) =/= missing end, ById),
    lists:sort(fun(A, B) -> maps:get(Key, A) >= maps:get(Key, B) end, With) ++ Without.

-doc """
The header and a line for each row, each column as wide as its widest
value or header, numbers aligned right, each line cut at Width.
""".
-spec table([atom()], [row()], pos_integer() | infinity) -> iodata().
table([], _Rows, _Width) ->
    [];
table(Columns, Rows, Width) ->
    Lines = [[header(Column) || Column <- Columns]
             | [[cell(Column, Row) || Column <- Columns] || Row <- Rows]],
    Widths = [lists:max([byte_size(lists:nth(I, Line)) || Line <- Lines])
              || I <- lists:seq(1, length(Columns))],
    [[cut(line(Columns, Line, Widths), Width), $\n] || Line <- Lines].

line(Columns, Cells, Widths) ->
    iolist_to_binary(lists:join($\s, padded(Columns, Cells, Widths))).

%% Each cell padded to its column's width, the last not on its right, so
%% no line ends in spaces.
padded([Column], [Cell], [Width]) -> [pad(align(Column), Cell, Width, true)];
padded([Column | Columns], [Cell | Cells], [Width | Widths]) ->
    [pad(align(Column), Cell, Width, false) | padded(Columns, Cells, Widths)].

pad(right, Cell, Width, _Last) -> [binary:copy(<<" ">>, Width - byte_size(Cell)), Cell];
pad(left, Cell, _Width, true) -> Cell;
pad(left, Cell, Width, false) -> [Cell, binary:copy(<<" ">>, Width - byte_size(Cell))].

cut(Line, infinity) -> Line;
cut(Line, Width) when byte_size(Line) =< Width -> Line;
cut(Line, Width) -> binary:part(Line, 0, Width).

header(pid) -> <<"PID">>;
header(tt) -> <<"TT">>;
header(state) -> <<"STAT">>;
header(time) -> <<"TIME">>;
header(pcpu) -> <<"%CPU">>;
header(rss) -> <<"RSS">>;
header(comm) -> <<"COMMAND">>;
header(command) -> <<"COMMAND">>.

align(Column) when Column =:= pid; Column =:= time; Column =:= pcpu; Column =:= rss -> right;
align(_Column) -> left.

cell(Column, Row) ->
    case maps:get(Column, Row) of
        missing -> <<"-">>;
        Value when is_integer(Value) -> integer_to_binary(Value);
        Value when is_float(Value) -> float_to_binary(Value, [{decimals, 1}]);
        Value -> Value
    end.
