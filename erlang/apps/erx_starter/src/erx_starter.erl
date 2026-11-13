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
* **rc.conf.** The process does no file operation itself. The rc.conf
  process (erx_starter_rc) reads and writes rc.conf for it and answers
  each request as a reply the process takes as a message, and
  erx_start_table:read_answered/3 decides
  what each answer leads to: a text, or no file, makes the table; a
  failure reads again after a backoff that never gives up, and the first
  one, when no table has been made, makes it from the manifest's rows
  alone, so they start while the storage domain is down. The first read
  follows the domain service's answer that the system domain's namespace
  is in place (erx_domain:system_namespace/0), so a storage domain that
  comes up on its first boot, its grant made within the grant's deadline,
  has installed the system domain's data grant before it; a failure means
  the storage domain is down, ended before its grant was made, or did not
  make it in time. Until a read
  has answered, rows/0 says rc.conf is unread, and a command that writes
  rc.conf is refused with `rc_conf_unread`, so it never writes over
  settings it has not read.
* **Making the table.** Each time the table is made from rc.conf's text
  the text is recorded in the keepers' branch, and the rows' keepers are
  reconciled with it (erx_start_table:reconcile/3): a held row no longer
  enabled stops, a running row whose settings changed is restarted, an
  enabled row neither held nor marked stopped starts, and a row that is
  down or stopped stays so whatever its settings.
* **Commands.** Until the table is first made every command is refused
  with `rc_conf_unread`. command/1 takes a command parse_ctl/1 made
  (erx_start_table:apply_ctl/4 decides it). A command that writes rc.conf
  hands the new text to the rc.conf process, which writes it to a
  temporary file and renames that over rc.conf; the table commits the
  text only once the write succeeded, and answers commands in order, one
  write at a time.
  `stop` of an enabled row marks it stopped, and `start` or `enable` of
  the row clears the mark as it starts the row.
* **Restart.** A restarted process makes the table from the text the
  keepers' branch recorded, and changes nothing the branch holds until
  its own read of rc.conf answers: a row rc.conf enabled is not stopped
  because the file cannot be read, and a row that is down or stopped
  stays so. With no record, it starts as at boot. A write the ended
  process asked for lands before this read or not at all, as the rc.conf
  process serves only the process whose read came last, so the text the
  read finds is the file's until this process writes it.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/2, command/1, rows/0, rc_conf/0]).
-export_type([source/0, answer/0, run/0]).
-export([manifest_table/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

%% The manifest's part of the table: its start rows in order, the services
%% each principal's session template is granted, each principal's number,
%% its manifest index plus one, by its name, and the configured domains'
%% names in boot order, which `/proc/apps` shows beside the rows.
-type manifest() :: #{rows := [erx_start_table:row()], grants := #{binary() => [binary()]},
                      principals := #{binary() => pos_integer()}, boot_order := [binary()]}.

%% Where the table reads the manifest from: the system manifest, or a
%% manifest table made beforehand, for the tests.
-type source() :: system | manifest().
%% command/1's answer: ok, a refusal of the command as the table stands, or
%% `{failed, Reason}` for a command the table admitted that could not be
%% carried out: rc.conf's write, or the supervisor's start, failed.
-type answer() :: ok | {error, erx_start_table:ctl_error() | rc_conf_unread | {failed, term()}}.
%% Where an enabled row's session stands, from the keepers' branch alone
%% (erx_starter_sup:held/0): `running`, its supervisor alive; `down`, its
%% supervisor ended at its intensity; `stopped`, marked so by `stop`; or
%% `starting`, neither held nor marked, which the table starts at its next
%% reconciling, as at boot before rc.conf's read answers. A row that is not
%% enabled is `none`.
-type run() :: running | down | stopped | starting | none.

-doc "The table over Source's rows, with rc.conf in Directory.".
-spec start_link(source(), binary()) -> gen_server:start_ret().
start_link(Source, Directory) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Source, Directory}, []).

-doc """
Carries out Command, from erx_start_table:parse_ctl/1: ok, or {error,
Reason}, with erx_start_table:apply_ctl/4's refusals, `rc_conf_unread`
before rc.conf has been read, and `{failed, Why}` for a write's error or,
for a start, the supervisor's refusal (answer()). An `enable` answers ok
once rc.conf is written, as the setting then stands, even when the start
of its row that follows fails.
""".
-spec command(erx_start_table:command()) -> answer().
command(Command) ->
    gen_server:call(?MODULE, {command, Command}, infinity).

-doc """
The table: each manifest row merged, with the key `run` (run()), or
`unmade` before the table is first made; the lines of rc.conf that were
skipped; `rc_conf`, `read` once this process's read of rc.conf has
answered, `unread` before; and `boot_order`, the configured domains'
names in the manifest's boot order. While rc.conf is unread the rows are
those of the text the keepers' branch recorded, or of the manifest alone,
and may not be what the file sets.
""".
-spec rows() -> #{rows := [map()] | unmade, skipped := [erx_start_table:local()], rc_conf := read | unread,
                  boot_order := [binary()]}.
rows() ->
    gen_server:call(?MODULE, rows).

-doc """
The text of rc.conf the table is made from, which `/apps/rc.conf` shows: the
text of the last read or write, the text the keepers' branch recorded while
rc.conf is unread, or the empty text before either.
""".
-spec rc_conf() -> binary().
rc_conf() ->
    gen_server:call(?MODULE, rc_conf).

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
        {ok, Domains} ?= strings(View, domains),
        {ok, Order} ?= collect(View, boot_order),
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
               principals => #{Principal => Number || {Number, Principal} <- lists:enumerate(Names)},
               boot_order => [lists:nth(Domain + 1, Domains) || #{domain := Domain} <- Order]}}
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

init({system, Directory}) ->
    Manifest = case manifest_table(erx_build:system_manifest()) of
                   {ok, Table} ->
                       Table;
                   error ->
                       logger:error("erx_starter: the system manifest's start rows cannot be read; no row starts"),
                       #{rows => [], grants => #{}, principals => #{}, boot_order => []}
               end,
    init({Manifest, Directory});
init({#{} = Manifest, Directory}) ->
    {ok, Manifest#{directory => Directory, text => <<>>, local => {unread, 0}, merged => none, skipped => [],
                   reader => none, writer => none, queue => queue:new()}, {continue, read}}.

%% The first read of rc.conf waits for the system domain's namespace: the
%% table asks the domain service now and reads once it answers
%% (namespace_answered/2).
handle_continue(read, #{rows := []} = State) ->
    {noreply, State#{local := read, merged := []}};
handle_continue(read, State) ->
    Recorded = case erx_starter_sup:recorded() of
                   {ok, Text} -> make(Text, State);
                   none -> State
               end,
    {noreply, Recorded#{reader := {namespace, erx_domain:system_namespace()}}}.

handle_call({command, Command}, From, #{writer := none, queue := Queue} = State) ->
    true = queue:is_empty(Queue),
    {noreply, run(Command, From, State)};
handle_call({command, Command}, From, #{queue := Queue} = State) ->
    {noreply, State#{queue := queue:in({Command, From}, Queue)}};
handle_call(rows, _From, State) ->
    {reply, table(State), State};
handle_call(rc_conf, _From, #{text := Text} = State) ->
    {reply, Text, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% The reader is the one request that comes before a table can be made from
%% rc.conf: the wait for the system domain's namespace, {namespace, Request},
%% before the first read, and each read after, {rc_conf, Request}.
handle_info(read, #{reader := none} = State) ->
    {noreply, read(State)};
handle_info(Message, #{reader := Reader, writer := Writer} = State) ->
    {noreply, case {reader_answer(Message, Reader), response(Message, request(Writer))} of
                  {{namespace, Answer}, none} ->
                      namespace_answered(Answer, State#{reader := none});
                  {{rc_conf, Read}, none} ->
                      read_answered(Read, State#{reader := none});
                  {none, {answer, Written}} ->
                      {_Request, From, Command, Text} = Writer,
                      next(written(Written, From, Command, Text, State#{writer := none}));
                  {none, none} ->
                      State
              end}.

%% ---------------------------------------------------------------------------
%% rc.conf

%% The domain service's answer to the wait for the system domain's namespace,
%% after which the first read of rc.conf follows. ok: each files grant to the
%% system domain has settled, its data grant installed if the storage domain
%% came up and was granted it in time, so the read finds the file or its
%% absence. An error is a domain service that ended, which ends the system
%% domain; the read follows all the same, and read_answered/3 decides what its
%% answer leads to.
namespace_answered(ok, State) ->
    read(State);
namespace_answered({error, Why}, State) ->
    logger:warning("erx_starter: no answer to the wait for the system domain's namespace: ~0P", [Why, 8]),
    read(State).

read(#{directory := Directory} = State) ->
    State#{reader := {rc_conf, erx_starter_rc:read(Directory)}}.

%% The reader's answer that Message carries, tagged with the reader's kind, or
%% none.
reader_answer(Message, {Kind, Request}) ->
    case response(Message, Request) of
        {answer, Answer} -> {Kind, Answer};
        none -> none
    end;
reader_answer(_Message, none) ->
    none.

%% The rc.conf process's answer to Request that Message carries, its end
%% before it answered taken as {error, Why}, or none for a message that is
%% not Request's answer.
response(_Message, none) ->
    none;
response(Message, Request) ->
    case gen_server:check_response(Message, Request) of
        {reply, Reply} -> {answer, Reply};
        {error, {Why, _Server}} -> {answer, {error, Why}};
        no_reply -> none
    end.

request({Request, _From, _Command, _Text}) -> Request;
request(none) -> none.

%% Carries out what erx_start_table:read_answered/3 decides for the read's
%% Answer.
read_answered(Answer, #{local := Local, merged := Merged} = State) ->
    {Reading, Effects} = erx_start_table:read_answered(Answer, Local, Merged =/= none),
    lists:foldl(fun effect/2, State#{local := Reading}, Effects).

effect({log, Format, Args}, State) ->
    logger:warning(Format, Args),
    State;
effect({apply, Text}, State) ->
    apply_text(Text, State);
effect({retry, Delay}, State) ->
    _ = erlang:send_after(Delay, self(), read),
    State.

%% The table made from Text, rc.conf's text or the empty text of the manifest's
%% rows alone, recorded in the keepers' branch first, with the rows' keepers
%% reconciled with it.
apply_text(Text, State) ->
    ok = erx_starter_sup:record(Text),
    #{merged := After} = Made = make(Text, State),
    {Rows, Stopped} = erx_starter_sup:held(),
    Held = #{Name => {running_or_down(Run), kept(Row)} || {Name, Run, Row} <- Rows},
    {Stop, Start} = erx_start_table:reconcile(Held, Stopped, After),
    lists:foreach(fun erx_starter_sup:stop/1, Stop),
    lists:foreach(fun(Name) -> start_row(Name, Made) end, Start),
    Made.

%% The table rc.conf's Text makes, with every skipped line and refused row
%% logged; no keeper changes.
make(Text, #{rows := Rows, grants := Grants} = State) ->
    Local = case erx_start_table:parse_rc_conf(Text) of
                {ok, Parsed} ->
                    Parsed;
                {error, too_large} ->
                    logger:warning("erx_starter: rc.conf is over ~b bytes and sets nothing",
                                   [erx_start_table:rc_conf_limit()]),
                    []
            end,
    {Merged, Skipped} = erx_start_table:merge(Rows, Local, Grants),
    _ = [logger:warning("erx_starter: rc.conf line ~b skipped: ~0p", [Line, Reason])
         || {skipped, Line, Reason} <- Skipped],
    _ = [logger:warning("erx_starter: row ~ts refused: ~0p", [Name, Reason])
         || #{principal := Name, status := {refused, Reason}} <- Merged],
    State#{text := Text, merged := Merged, skipped := Skipped}.

%% ---------------------------------------------------------------------------
%% Commands

%% Before any table is made every command is refused, so none answers ok and is
%% undone when the table is made. A command that writes rc.conf before the file
%% has been read is refused, so it never writes over settings it has not read;
%% start and stop act on the table as it is.
run(_Command, From, #{merged := none} = State) ->
    gen_server:reply(From, {error, rc_conf_unread}),
    next(State);
run(Command, From, #{text := Text, rows := Rows, grants := Grants, local := Local} = State) ->
    case erx_start_table:apply_ctl(Command, Text, Rows, Grants) of
        {rc_conf, _} when Local =/= read ->
            gen_server:reply(From, {error, rc_conf_unread}),
            next(State);
        {rc_conf, Written} ->
            Request = erx_starter_rc:write(maps:get(directory, State), Written),
            State#{writer := {Request, From, Command, Written}};
        Action ->
            gen_server:reply(From, act(Action, State)),
            next(State)
    end.

act({start_row, Name}, State) ->
    start_row(Name, State);
act({start_once, Name, Start}, #{principals := Principals}) ->
    started(erx_starter_sup:start_once(Name, map_get(Name, Principals), Start));
act({stop, Name}, State) ->
    case row(Name, State) of
        {ok, _Row} -> erx_starter_sup:stop_row(Name);
        none -> erx_starter_sup:stop(Name)
    end;
act({error, _} = Refused, _State) ->
    Refused.

%% A write that succeeded commits its text, and the table made from it
%% starts an enabled row that is neither held nor marked.
written(ok, From, Command, Text, State) ->
    ok = clear_for_enable(Command),
    Applied = apply_text(Text, State),
    gen_server:reply(From, ok),
    Applied;
%% A write that failed may still have renamed its text over rc.conf (a
%% storage domain that ended after the rename and before its answer), so the
%% table reads rc.conf again, as at a restart, rather than keep a text the
%% file may no longer hold.
written({error, Reason}, From, _Command, _Text, State) ->
    logger:warning("erx_starter: rc.conf cannot be written: ~0P", [Reason, 8]),
    gen_server:reply(From, {error, {failed, Reason}}),
    read(State#{local := {unread, 0}}).

%% An `enable`, once its write of rc.conf succeeded, clears its row's stopped
%% mark and the spec of a row that is down (erx_starter_sup:clear/1) before
%% the table is made from the text, so making the table starts the row, and a
%% table that ends after the clear finds the row unmarked and not held and
%% starts it once its own read of rc.conf answers. A table that ends while the
%% write is in progress leaves the mark, and the row stays stopped (TODO.md).
clear_for_enable({enable, Name, _Settings}) -> erx_starter_sup:clear(Name);
clear_for_enable(_Command) -> ok.

%% The next queued command, once no write is in progress.
next(#{writer := none, queue := Queue} = State) ->
    case queue:out(Queue) of
        {{value, {Command, From}}, Rest} -> run(Command, From, State#{queue := Rest});
        {empty, _} -> State
    end;
next(State) ->
    State.

%% Starts row Name's supervisor, if the row is enabled and not running.
start_row(Name, State) ->
    case row(Name, State) of
        {ok, Row} -> started(erx_starter_sup:start_row(Name, Row));
        none -> ok
    end.

started({ok, _Pid}) -> ok;
started({error, {already_started, _}}) -> ok;
started({error, Why}) -> {error, {failed, Why}}.

%% What enabled row Name's supervisor keeps (erx_starter_row:row()), or none
%% for a row that is not enabled.
row(Name, #{merged := Merged, principals := Principals}) when is_list(Merged) ->
    case [Row || #{principal := Principal, status := enabled} = Row <- Merged, Principal =:= Name] of
        [#{display := Display, restarts := Restarts, period := Period}] ->
            Start = case Display of
                        none -> #{};
                        _ -> #{display => Display}
                    end,
            {ok, #{principal => map_get(Name, Principals), start => Start, restarts => Restarts, period => Period}};
        [] ->
            none
    end;
row(_Name, #{merged := none}) ->
    none.

%% What a row's supervisor keeps its session with, as erx_start_table:kept/1
%% gives it for a merged row.
kept(#{start := Start, restarts := Restarts, period := Period}) ->
    #{display => maps:get(display, Start, none), restarts => Restarts, period => Period}.

table(#{merged := none, skipped := Skipped, local := Local, boot_order := Order}) ->
    #{rows => unmade, skipped => Skipped, rc_conf => reading(Local), boot_order => Order};
table(#{merged := Merged, skipped := Skipped, local := Local, boot_order := Order}) ->
    {Rows, Stopped} = erx_starter_sup:held(),
    Runs = #{Name => running_or_down(Run) || {Name, Run, _Row} <- Rows},
    #{rows => [Row#{run => run_state(Row, Runs, Stopped)} || Row <- Merged], skipped => Skipped,
      rc_conf => reading(Local), boot_order => Order}.

reading(read) -> read;
reading({unread, _Failures}) -> unread.

running_or_down(Pid) when is_pid(Pid) -> running;
running_or_down(down) -> down.

%% An enabled row's run(): held, marked stopped, or neither, which is a row
%% the table has yet to start.
run_state(#{status := enabled, principal := Name}, Runs, Stopped) ->
    case Runs of
        #{Name := Run} -> Run;
        #{} ->
            case lists:member(Name, Stopped) of
                true -> stopped;
                false -> starting
            end
    end;
run_state(_Row, _Runs, _Stopped) ->
    none.
