%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter).
-moduledoc """
The start service's table (docs/design-apps.md, "The start table" and
"Concurrency"): one process that owns the merged table, the manifest's
`start` rows with `rc.conf` over them, and starts and stops the rows'
supervisors in the keepers' branch (erx_starter_sup). Every decision is
erx_start_table's; this process carries them out.

* **The manifest.** At its start the process reads the start rows, each
  principal's number and the services each session template is granted
  from the system manifest (manifest_table/1), as erx_build reads its
  tables. A manifest with no start row makes an empty table, and nothing
  more happens: no rc.conf is read.
* **rc.conf.** The process does no file operation itself. A worker reads
  `start/rc.conf` under the system domain's /data (erx_starter_rc); the
  table starts its rows once the first read answers. A read that fails,
  the storage domain not being up, makes the table from the manifest's
  rows alone and is tried again every ?RETRY_MS milliseconds, at most
  ?ATTEMPTS times; when a later read succeeds the table is merged again,
  and a row the file changes is stopped and started again
  (erx_start_table:changes/2). Until a read has answered, a command that
  writes rc.conf is refused with `rc_conf_unread`, so it never writes over
  settings it has not read.
* **Commands.** command/1 takes a command parse_ctl/1 made
  (erx_start_table:apply_ctl/4 decides it). A command that writes rc.conf
  hands the new text to a worker, which writes it to a temporary file and
  renames that over rc.conf; the table commits the text only once the
  write succeeded, and answers commands in order, one write at a time.
* **Restart.** A restarted process reads the manifest and rc.conf again,
  and then stops the held rows that are no longer enabled and starts the
  enabled rows the keepers' branch does not hold
  (erx_start_table:reconcile/2), so no kept session ends and a row that is
  down stays down.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/1, command/1, rows/0]).
-export_type([source/0]).
-export([manifest_table/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-define(RETRY_MS, 2000).
-define(ATTEMPTS, 30).

%% The manifest's part of the table: its start rows in order, the services
%% each principal's session template is granted, and each principal's
%% number, its manifest index plus one, by its name.
-type manifest() :: #{rows := [erx_start_table:row()], grants := #{binary() => [binary()]},
                      principals := #{binary() => pos_integer()}}.

%% Where the table reads the manifest from: the system manifest, or a
%% manifest table made beforehand, for the tests.
-type source() :: system | manifest().

-spec start_link(source()) -> gen_server:start_ret().
start_link(Source) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Source, []).

-doc """
Carries out Command, from erx_start_table:parse_ctl/1: ok, or {error,
Reason}, with erx_start_table:apply_ctl/4's reasons, `rc_conf_unread`
before rc.conf has been read, a write's error, and, for a start, the
supervisor's refusal.
""".
-spec command(erx_start_table:command()) -> ok | {error, term()}.
command(Command) ->
    gen_server:call(?MODULE, {command, Command}, infinity).

-doc """
The table: each manifest row merged, with `run`, `running`, `down` or
`stopped` for an enabled row and `none` for any other, and the lines of
rc.conf that were skipped.
""".
-spec rows() -> #{rows := [map()], skipped := [erx_start_table:local()]}.
rows() ->
    gen_server:call(?MODULE, rows).

%% ---------------------------------------------------------------------------
%% The manifest

-doc """
The start table's part of the system manifest `file:read_file/1` returned,
or error for one it could not read or open. Pure, for its tests.
""".
-spec manifest_table({ok, binary()} | {error, term()}) -> {ok, manifest()} | error.
manifest_table({ok, Manifest}) ->
    maybe
        {ok, View} ?= erx_manifest:open(Manifest),
        {ok, Names} ?= strings(View, principals),
        {ok, Services} ?= strings(View, services),
        {ok, Sessions} ?= collect(View, sessions),
        {ok, Facets} ?= collect(View, facets),
        {ok, Starts} ?= collect(View, starts),
        Name = fun(Index) -> lists:nth(Index + 1, Names) end,
        Service = fun(Index) -> lists:nth(Index + 1, Services) end,
        Template = fun(Session) -> Name(maps:get(principal, lists:nth(Session + 1, Sessions))) end,
        Rows = [#{principal => Name(Principal), enable => Flags band ?ERX_MF_START_ENABLED =/= 0,
                  display => display(Display, Service), restarts => Restarts, period => Period}
                || #{principal := Principal, flags := Flags, display := Display, restarts := Restarts,
                     restart_period_s := Period} <- Starts],
        Granted = [{Template(Session), Service(Index)}
                   || #{grantee_kind := ?ERX_MF_GRANTEE_SESSION, grantee := Session, service := Index} <- Facets],
        {ok, #{rows => Rows,
               grants => maps:groups_from_list(fun({P, _}) -> P end, fun({_, S}) -> S end, Granted),
               principals => #{Principal => Number || {Number, Principal} <- lists:enumerate(Names)}}}
    else
        _ -> error
    end;
manifest_table({error, _}) ->
    error.

display(?ERX_MF_NONE, _Service) -> none;
display(Index, Service) -> Service(Index).

%% A table's records in order; the manifest reader has checked every index
%% they hold.
collect(View, Table) ->
    case erx_manifest:fold(View, Table, fun(Record, Acc) -> [Record | Acc] end, []) of
        {ok, Records} -> {ok, lists:reverse(Records)};
        Error -> Error
    end.

%% The names of a table's records, in order.
strings(View, Table) ->
    maybe
        {ok, Records} ?= collect(View, Table),
        Read = [erx_manifest:string(View, Ref) || #{name := Ref} <- Records],
        true ?= lists:all(fun(Result) -> element(1, Result) =:= ok end, Read),
        {ok, [String || {ok, String} <- Read]}
    end.

%% ---------------------------------------------------------------------------
%% The process

init(system) ->
    Manifest = case manifest_table(erx_build:system_manifest()) of
                   {ok, Table} ->
                       Table;
                   error ->
                       logger:error("erx_starter: the system manifest's start rows cannot be read; no row starts"),
                       #{rows => [], grants => #{}, principals => #{}}
               end,
    init(Manifest);
init(#{} = Manifest) ->
    {ok, Manifest#{text => <<>>, local => unread, attempts => 0, merged => none, skipped => [],
                   reader => none, writer => none, queue => queue:new()}, {continue, read}}.

handle_continue(read, #{rows := []} = State) ->
    {noreply, State#{local := read, merged := []}};
handle_continue(read, State) ->
    {noreply, read(State)}.

handle_call({command, Command}, From, #{writer := none, queue := Queue} = State) ->
    true = queue:is_empty(Queue),
    {noreply, run(Command, From, State)};
handle_call({command, Command}, From, #{queue := Queue} = State) ->
    {noreply, State#{queue := queue:in({Command, From}, Queue)}};
handle_call(rows, _From, State) ->
    {reply, table(State), State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, Result}, #{reader := Ref} = State) ->
    {noreply, read_answered(Result, State#{reader := none})};
handle_info({'DOWN', Ref, process, _, Result}, #{writer := {Ref, From, Command, Text}} = State) ->
    {noreply, next(written(Result, From, Command, Text, State#{writer := none}))};
handle_info(read, #{reader := none} = State) ->
    {noreply, read(State)};
handle_info(_Message, State) ->
    {noreply, State}.

%% ---------------------------------------------------------------------------
%% rc.conf

read(#{attempts := Attempts} = State) ->
    {_, Ref} = spawn_monitor(fun() -> exit({read, erx_starter_rc:read()}) end),
    State#{reader := Ref, attempts := Attempts + 1}.

read_answered({read, {ok, Text}}, State) ->
    apply_text(Text, State#{local := read});
read_answered({read, absent}, State) ->
    apply_text(<<>>, State#{local := read});
read_answered(Failed, #{attempts := Attempts} = State) ->
    Reason = case Failed of
                 {read, {error, Error}} -> Error;
                 Crash -> Crash
             end,
    logger:warning("erx_starter: rc.conf cannot be read (attempt ~b of ~b): ~0P", [Attempts, ?ATTEMPTS, Reason, 8]),
    Started = case State of
                  #{merged := none} -> apply_text(<<>>, State);
                  _ -> State
              end,
    case Attempts < ?ATTEMPTS of
        true ->
            _ = erlang:send_after(?RETRY_MS, self(), read),
            Started;
        false ->
            Started#{local := unavailable}
    end.

%% The table rc.conf's Text makes, with the rows' keepers stopped and started
%% to match it.
apply_text(Text, #{rows := Rows, grants := Grants, merged := Before} = State) ->
    Local = case erx_start_table:parse_rc_conf(Text) of
                {ok, Parsed} ->
                    Parsed;
                {error, too_large} ->
                    logger:warning("erx_starter: rc.conf is over ~b bytes and sets nothing",
                                   [erx_start_table:rc_conf_limit()]),
                    []
            end,
    {After, Skipped} = erx_start_table:merge(Rows, Local, Grants),
    _ = [logger:warning("erx_starter: rc.conf line ~b skipped: ~0p", [Line, Reason])
         || {skipped, Line, Reason} <- Skipped],
    _ = [logger:warning("erx_starter: row ~ts refused: ~0p", [Name, Reason])
         || #{principal := Name, status := {refused, Reason}} <- After],
    {Stop, Start} = case Before of
                        none -> erx_start_table:reconcile([Name || {Name, _} <- erx_starter_sup:held()], After);
                        _ -> erx_start_table:changes(Before, After)
                    end,
    lists:foreach(fun erx_starter_sup:stop/1, Stop),
    Applied = State#{text := Text, merged := After, skipped := Skipped},
    lists:foreach(fun(Name) -> start_row(Name, Applied) end, Start),
    Applied.

%% ---------------------------------------------------------------------------
%% Commands

%% A command that writes rc.conf before the file has been read is refused, so it
%% never writes over settings it has not read; start and stop act on the table as it is.
run(Command, From, #{text := Text, rows := Rows, grants := Grants, local := Local} = State) ->
    case erx_start_table:apply_ctl(Command, Text, Rows, Grants) of
        {rc_conf, _} when Local =/= read ->
            gen_server:reply(From, {error, rc_conf_unread}),
            next(State);
        {rc_conf, Written} ->
            {_, Ref} = spawn_monitor(fun() -> exit({written, erx_starter_rc:write(Written)}) end),
            State#{writer := {Ref, From, Command, Written}};
        Action ->
            gen_server:reply(From, act(Action, State)),
            next(State)
    end.

act({start_row, Name}, State) ->
    start_row(Name, State);
act({start_once, Name, Start}, #{principals := Principals}) ->
    started(erx_starter_sup:start_once(Name, map_get(Name, Principals), Start));
act({stop, Name}, _State) ->
    erx_starter_sup:stop(Name);
act({error, _} = Refused, _State) ->
    Refused.

%% A write that succeeded commits its text; an `enable` also starts its row
%% when it is down or stopped with its settings unchanged.
written({written, ok}, From, Command, Text, State) ->
    Applied = apply_text(Text, State),
    _ = case Command of
            {enable, Name, _} -> start_row(Name, Applied);
            _ -> ok
        end,
    gen_server:reply(From, ok),
    Applied;
written(Failed, From, _Command, _Text, State) ->
    Reason = case Failed of
                 {written, {error, Error}} -> Error;
                 Crash -> Crash
             end,
    logger:warning("erx_starter: rc.conf cannot be written: ~0P", [Reason, 8]),
    gen_server:reply(From, {error, Reason}),
    State.

%% The next queued command, once no write is in progress.
next(#{writer := none, queue := Queue} = State) ->
    case queue:out(Queue) of
        {{value, {Command, From}}, Rest} -> run(Command, From, State#{queue := Rest});
        {empty, _} -> State
    end;
next(State) ->
    State.

%% Starts row Name's supervisor, if the row is enabled and not running.
start_row(Name, #{merged := Merged, principals := Principals}) ->
    case [Row || #{principal := Principal, status := enabled} = Row <- Merged, Principal =:= Name] of
        [#{display := Display, restarts := Restarts, period := Period}] ->
            Start = case Display of
                        none -> #{};
                        _ -> #{display => Display}
                    end,
            started(erx_starter_sup:start_row(Name, #{principal => map_get(Name, Principals), start => Start,
                                                      restarts => Restarts, period => Period}));
        [] ->
            ok
    end.

started({ok, _Pid}) -> ok;
started({error, {already_started, _}}) -> ok;
started({error, _} = Refused) -> Refused.

table(#{merged := none, skipped := Skipped}) ->
    #{rows => [], skipped => Skipped};
table(#{merged := Merged, skipped := Skipped}) ->
    Held = maps:from_list(erx_starter_sup:held()),
    #{rows => [Row#{run => run_state(Row, Held)} || Row <- Merged], skipped => Skipped}.

run_state(#{status := enabled, principal := Name}, Held) ->
    case maps:find(Name, Held) of
        {ok, down} -> down;
        {ok, _Pid} -> running;
        error -> stopped
    end;
run_state(_Row, _Held) ->
    none.
