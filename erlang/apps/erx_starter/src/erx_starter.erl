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
  principal's number and the `windows` services each session template is
  granted, the displays its rows may name, from the system manifest
  (manifest_table/1), as erx_build reads its tables. A manifest with no start row and no `apps` row makes an empty table, and nothing
  more happens: no rc.conf is read.
* **rc.conf.** The process does no file operation itself. The rc.conf
  process (erx_starter_rc) reads and writes rc.conf for it and answers
  each request as a reply the process takes as a message, and
  erx_start_table:read_answered/3 decides
  what each answer leads to: a text, or no file, makes the table; a
  failure reads again after a backoff that never gives up, and the first
  one, when no table has been made, makes it from the rows' published
  defaults (erx_start_table:published_defaults/1), so the rows the
  published card starts run while the storage domain is down and a row it
  ships off, which the unread file may have left on, does not. The first read
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
* **A row that names a display.** Its supervisor starts only once the
  domain service answers that the display's server has settled
  (erx_domain:server_settled/1): ready, or no longer starting, so a
  display that is down delays the row by at most its boot timeout and the
  row then starts all the same. The table asks once per display for every
  start waiting on it, and asks again at the next start, so it keeps no
  view of the display of its own. Until the answer the row is `starting`;
  a `start` command waiting on it is answered when its start is carried
  out, and `stop` of it answers the waiting start ok and starts nothing.
* **Package sets.** The package process publishes its set with
  packages/2, taken in turn with the commands. The table keeps the last
  set, recorded in the keepers' branch, and its rows follow the
  manifest's (erx_start_table:package_rows/3), each kept by a keeper of
  `{app, Name}`; every keeper of a name that neither the manifest nor the
  set holds is stopped before the answer, which so comes once each app the
  set drops has no session (docs/design-packaging.md, PK7); and once the
  table is made it is made again with the set's rows, so the boot's set
  starts the rows rc.conf enables.
* **Restart.** A restarted process makes the table from the text and the
  package set the keepers' branch recorded, and changes nothing the
  branch holds until its own read of rc.conf answers: a row rc.conf
  enabled is not stopped because the file cannot be read, and a row that
  is down or stopped stays so. With no record, it starts as at boot. A write the ended
  process asked for lands before this read or not at all, as the rc.conf
  process serves only the process whose read came last, so the text the
  read finds is the file's until this process writes it.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/2, command/1, rows/0, packages/2]).
-export_type([source/0, answer/0, run/0, basis/0]).
-export([manifest_table/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

%% The manifest's part of the table: its start rows in order, the `windows`
%% services each principal's session template is granted (the displays its
%% row may name), each principal's number,
%% its manifest index plus one, by its name, and the configured domains'
%% names in boot order, which `/proc/apps` shows beside the rows; the names of
%% its `windows` services, the displays an app's row may name; and each image
%% package's default `enable` by its app name, or none for a manifest with no
%% `apps` row, which runs no package process.
-type manifest() :: #{rows := [erx_start_table:row()], grants := #{binary() => [binary()]},
                      principals := #{binary() => pos_integer()}, boot_order := [binary()],
                      windows := [binary()], packages := none | #{binary() => boolean()}}.

%% Where the table reads the manifest from: the system manifest, or a
%% manifest table made beforehand, for the tests.
-type source() :: system | manifest().
%% command/1's answer: ok, a refusal of the command as the table stands, or
%% `{failed, Reason}` for a command the table admitted that could not be
%% carried out: rc.conf's write, or the supervisor's start, failed.
-type answer() :: ok | {error, erx_start_table:ctl_error() | rc_conf_unread | {failed, term()}}.
%% What the table is made from: a text of rc.conf over the manifest's and the
%% package set's rows, the empty text being no settings, or, after a boot's
%% read failed, the published card's defaults of those rows with no settings
%% (erx_start_table:published_defaults/1). The keepers' branch records it.
-type basis() :: {rc_conf, binary()} | card_defaults.
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
Takes Set, the package set the package process Lifetime publishes
(docs/design-packaging.md, "Boot and recovery", step 5), and answers ok
once every app the set drops has no session; {error, eio}, taking nothing
of the set, when Lifetime has ended by the time the table takes it, as
every taker of a lifetime's requests refuses them ("The package
lifetime"); or {error, no_table} while no table runs, which ends the
publishing lifetime as a failed change does.
""".
-spec packages(pid(), [erx_pkg_plan:published()]) -> ok | {error, eio | no_table}.
packages(Lifetime, Set) ->
    try gen_server:call(?MODULE, {packages, Lifetime, Set}, infinity)
    catch exit:{noproc, _} -> {error, no_table}
    end.

-doc """
The table: each manifest row merged, with the key `run` (run()), or
`unmade` before the table is first made; the lines of rc.conf that were
skipped; `rc_conf`, `read` once this process's read of rc.conf has
answered, `unread` before; and `boot_order`, the configured domains'
names in the manifest's boot order. While rc.conf is unread the rows are
those of the text the keepers' branch recorded, or the rows' published
defaults, and may not be what the file sets.
""".
-spec rows() -> #{rows := [map()] | unmade, skipped := [erx_start_table:local()], rc_conf := read | unread,
                  boot_order := [binary()]}.
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
        {ok, ServiceRecords} ?= collect(View, services),
        {ok, Services} ?= names(View, ServiceRecords),
        {ok, Sessions} ?= collect(View, sessions),
        {ok, Facets} ?= collect(View, facets),
        {ok, Starts} ?= collect(View, starts),
        {ok, Domains} ?= strings(View, domains),
        {ok, Order} ?= collect(View, boot_order),
        Name = fun(Index) -> lists:nth(Index + 1, Names) end,
        Service = fun(Index) -> lists:nth(Index + 1, Services) end,
        %% A display is a service of the windows interface (AP5), so a
        %% template's grant of any other service names no display.
        Windows = fun(Index) ->
                          maps:get(interface, lists:nth(Index + 1, ServiceRecords)) =:= ?ERX_SERVICE_WINDOWS
                  end,
        %% The app template names no principal: its grants are the apps',
        %% which no start row of the manifest takes (docs/design-packaging.md,
        %% "The start table's rows").
        TemplatePrincipal = fun(Session) -> maps:get(principal, lists:nth(Session + 1, Sessions)) end,
        Rows = [#{principal => Name(Principal), enable => Flags band ?ERX_MF_START_ENABLED =/= 0,
                  published_enable => Flags band ?ERX_MF_START_PUBLISHED_ENABLED =/= 0,
                  display => display(Display, Service), restarts => Restarts, period => Period}
                || #{principal := Principal, flags := Flags, display := Display, restarts := Restarts,
                     restart_period_s := Period} <- Starts],
        Granted = [{Name(TemplatePrincipal(Session)), Service(Index)}
                   || #{grantee_kind := ?ERX_MF_GRANTEE_SESSION, grantee := Session, service := Index} <- Facets,
                      TemplatePrincipal(Session) =/= ?ERX_MF_NONE, Windows(Index)],
        {ok, #{rows => Rows,
               grants => maps:groups_from_list(fun({P, _}) -> P end, fun({_, S}) -> S end, Granted),
               principals => #{Principal => Number || {Number, Principal} <- lists:enumerate(Names)},
               boot_order => [lists:nth(Domain + 1, Domains) || #{domain := Domain} <- Order],
               windows => [Shown || {At, Shown} <- lists:enumerate(0, Services), Windows(At)],
               packages => package_defaults(erx_pkg_manifest:system_config(Manifest))}}
    else
        _ -> error
    end;
manifest_table({error, _}) ->
    error.

%% Each image package's default `enable`, from erx_pkg_manifest, the reader of the
%% manifest's package rows. A manifest it refuses runs no package process
%% (erx_pkg:system_config/2), so it gives none, as one with no `apps` row does.
package_defaults({ok, #{apps := #{}, packages := Packages}}) ->
    #{Name => Enabled || #{name := Name, enabled := Enabled} <- Packages};
package_defaults(_NoApps) ->
    none.

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
        names(View, Records)
    end.

names(View, Records) ->
    Read = [erx_manifest:string(View, Ref) || #{name := Ref} <- Records],
    maybe
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
                       #{rows => [], grants => #{}, principals => #{}, boot_order => [], windows => [],
                         packages => none}
               end,
    init({Manifest, Directory});
%% rows and grants are the manifest's; set is the last package set the table
%% took, whose rows and grants follow the manifest's (rows_and_grants/1).
init({#{rows := _, grants := _, packages := _, windows := _} = Manifest, Directory}) ->
    {ok, Manifest#{set => [], directory => Directory, basis => {rc_conf, <<>>}, local => {unread, 0}, merged => none,
                   skipped => [], reader => none, writer => none, queue => queue:new(), displays => #{}},
     {continue, read}}.

%% The first read of rc.conf waits for the system domain's namespace: the
%% table asks the domain service now and reads once it answers
%% (namespace_answered/2). A manifest with no start row and no package process
%% has no row to read rc.conf for. A restarted table takes the package set the
%% keepers' branch recorded, the empty set at boot, before it makes the table
%% from the recorded basis.
handle_continue(read, #{rows := [], packages := none} = State) ->
    {noreply, State#{local := read, merged := []}};
handle_continue(read, State) ->
    WithSet = State#{set := erx_starter_records:recorded_set()},
    Recorded = case erx_starter_records:recorded() of
                   {ok, Basis} -> make(WithSet#{basis := Basis});
                   none -> WithSet
               end,
    {noreply, Recorded#{reader := {namespace, erx_domain:system_namespace()}}}.

handle_call({command, Command}, From, State) ->
    {noreply, take(Command, From, State)};
handle_call({packages, Lifetime, Set}, From, State) ->
    {noreply, take({packages, Lifetime, Set}, From, State)};
handle_call(rows, _From, State) ->
    {reply, table(State), State}.

%% A command or a publication is carried out at once when no write of rc.conf is
%% in progress, and otherwise queued behind it, so the table takes them one at a time.
take(Request, From, #{writer := none, queue := Queue} = State) ->
    true = queue:is_empty(Queue),
    run(Request, From, State);
take(Request, From, #{queue := Queue} = State) ->
    State#{queue := queue:in({Request, From}, Queue)}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% The reader is the one request that comes before a table can be made from
%% rc.conf: the wait for the system domain's namespace, {namespace, Request},
%% before the first read, and each read after, {rc_conf, Request}. Any other
%% message may be the domain service's answer to a wait for a display
%% (display_answered/2), which drops one that is not, a stray or a stale
%% timer's.
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
                      display_answered(Message, State)
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
    apply_basis({rc_conf, Text}, State);
effect(card_defaults, State) ->
    apply_basis(card_defaults, State);
effect({retry, Delay}, State) ->
    _ = erlang:send_after(Delay, self(), read),
    State.

%% The table made from Basis, recorded in the keepers' branch first, with the
%% rows' keepers reconciled with it.
apply_basis(Basis, State) ->
    ok = erx_starter_records:record(Basis),
    #{merged := After} = Made = make(State#{basis := Basis}),
    {Rows, Stopped} = erx_starter_sup:held(),
    Held = #{Name => {running_or_down(Run), kept(Row)} || {Name, Run, Row} <- Rows},
    {Stop, Start} = erx_start_table:reconcile(Held, Stopped, After),
    lists:foreach(fun erx_starter_sup:stop/1, Stop),
    lists:foldl(fun(Name, Acc) -> start_row(Name, none, Acc) end, Made, Start).

%% A package set, recorded in the keepers' branch first: every keeper of a name
%% neither the manifest nor the set holds is then stopped, its session ended,
%% before the table answers (PK7), and a made table is made again with the set's
%% rows. A table that ends between the record and the stops leaves a dropped
%% app's row supervisor that the restarted table has no row for, which its
%% first reconciling stops (erx_start_table:reconcile/3), and never a row of
%% the old set that it could start again; a keeper of the app's started once
%% runs until the next set, which the publication's lifetime, ended by the
%% failed call, publishes from its recovery.
publish(Set, #{principals := Principals} = State) ->
    ok = erx_starter_records:record_set(Set),
    Apps = #{Name => true || #{name := Name} <- Set},
    Dropped = [Name || Name <- erx_starter_sup:keeping(), not is_map_key(Name, Principals),
                       not is_map_key(Name, Apps)],
    lists:foreach(fun erx_starter_sup:stop/1, Dropped),
    Published = lists:foldl(fun unwait/2, State#{set := Set}, Dropped),
    case Published of
        #{merged := none} -> Published;
        #{basis := Basis} -> apply_basis(Basis, Published)
    end.

%% The table's rows and the `windows` services each row's principal is granted:
%% the manifest's, then the package set's (erx_start_table:package_rows/3),
%% each at its published default while the table's basis is the card's defaults.
rows_and_grants(#{rows := Rows, grants := Grants, set := Set, packages := Defaults, windows := Windows,
                  basis := Basis}) ->
    {AppRows, AppGrants} = erx_start_table:package_rows(Set, defaults(Defaults), Windows),
    Table = case Basis of
                card_defaults -> erx_start_table:published_defaults(Rows ++ AppRows);
                {rc_conf, _Text} -> Rows ++ AppRows
            end,
    {Table, maps:merge(Grants, AppGrants)}.

%% A manifest whose package rows were not read sends no set; one that does has
%% its defaults.
defaults(none) -> #{};
defaults(#{} = Defaults) -> Defaults.

%% The table the state's basis makes, with every skipped line and refused row
%% logged; no keeper changes.
make(State) ->
    {Rows, Grants} = rows_and_grants(State),
    Local = case erx_start_table:parse_rc_conf(text(State)) of
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
    State#{merged := Merged, skipped := Skipped}.

%% The text of rc.conf the table is made from: the card's defaults set nothing.
text(#{basis := {rc_conf, Text}}) -> Text;
text(#{basis := card_defaults}) -> <<>>.

%% ---------------------------------------------------------------------------
%% Commands

%% Before any table is made every command is refused, so none answers ok and is
%% undone when the table is made. A command that writes rc.conf before the file
%% has been read is refused, so it never writes over settings it has not read;
%% start and stop act on the table as it is. A publication is taken whether or not
%% the table is made, unless its lifetime has ended by the time the table takes
%% it, its caller gone with it, and the next lifetime's recovery publishes in
%% its place.
run({packages, Lifetime, Set}, From, State) ->
    case is_process_alive(Lifetime) of
        true ->
            Published = publish(Set, State),
            gen_server:reply(From, ok),
            next(Published);
        false ->
            gen_server:reply(From, {error, eio}),
            next(State)
    end;
run(_Command, From, #{merged := none} = State) ->
    gen_server:reply(From, {error, rc_conf_unread}),
    next(State);
run(Command, From, #{local := Local} = State) ->
    {Rows, Grants} = rows_and_grants(State),
    case erx_start_table:apply_ctl(Command, text(State), Rows, Grants) of
        {rc_conf, _} when Local =/= read ->
            gen_server:reply(From, {error, rc_conf_unread}),
            next(State);
        {rc_conf, Written} ->
            Request = erx_starter_rc:write(maps:get(directory, State), Written),
            State#{writer := {Request, From, Command, Written}};
        {start_row, Name} ->
            next(start_row(Name, From, State));
        {stop, Name} = Action ->
            gen_server:reply(From, act(Action, State)),
            next(unwait(Name, State));
        Action ->
            gen_server:reply(From, act(Action, State)),
            next(State)
    end.

act({start_once, Name, Start}, State) ->
    started(erx_starter_sup:start_once(Name, who(Name, State), with_default_display(Name, Start, State)));
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
    Applied = apply_basis({rc_conf, Text}, State),
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

%% Starts row Name's supervisor, if the row is enabled and not running, and
%% answers Reply, a `start` command's caller or none, with how the start went.
%% A row that names a display waits for the domain service's answer that the
%% display's server has settled (wait_display/4), and starts once it comes
%% (display_answered/2).
start_row(Name, Reply, State) ->
    start_row(Name, Reply, none, State).

%% Settled is the display whose answer has just come, so a row that names it
%% starts now; a row whose display changed while it waited waits for its new one.
%% A row whose supervisor runs is started already and waits for nothing.
start_row(Name, Reply, Settled, State) ->
    case row(Name, State) of
        {ok, #{start := #{display := Display}}} when Display =/= Settled ->
            case is_running(Name) of
                true -> answer(Reply, ok), State;
                false -> wait_display(Display, Name, Reply, State)
            end;
        {ok, Row} ->
            answer(Reply, started(erx_starter_sup:start_row(Name, Row))),
            State;
        none ->
            answer(Reply, ok),
            State
    end.

is_running(Name) ->
    {Rows, _Stopped} = erx_starter_sup:held(),
    lists:any(fun({Held, Run, _Row}) -> Held =:= Name andalso is_pid(Run) end, Rows).

answer(none, _Answer) -> ok;
answer(From, Answer) -> gen_server:reply(From, Answer).

%% A start waiting on Display, under the one request the table has out for
%% Display, which it sends with the first start that waits.
wait_display(Display, Name, Reply, #{displays := Displays} = State) ->
    Entry = case Displays of
                #{Display := {Request, Waiting}} -> {Request, [{Name, Reply} | Waiting]};
                #{} -> {erx_domain:server_settled(Display), [{Name, Reply}]}
            end,
    State#{displays := Displays#{Display => Entry}}.

%% The domain service's answer that Message carries to a wait for a display:
%% each start waiting on the display is carried out, oldest first, whether the
%% display came up or not. An error is a domain service that ended, which ends
%% the system domain; the rows start all the same, as the read of rc.conf
%% follows a failed wait for the namespace.
display_answered(Message, #{displays := Displays} = State) ->
    case [{Display, Answer, Waiting} || Display := {Request, Waiting} <- Displays,
                                        {answer, Answer} <- [response(Message, Request)]] of
        [{Display, Answer, Waiting}] ->
            ok = log_display(Display, Answer),
            lists:foldl(fun({Name, Reply}, Acc) -> start_row(Name, Reply, Display, Acc) end,
                        State#{displays := maps:remove(Display, Displays)}, lists:reverse(Waiting));
        [] ->
            State
    end.

log_display(_Display, ok) ->
    ok;
log_display(Display, {error, Why}) ->
    logger:warning("erx_starter: no answer to the wait for display ~ts: ~0P", [Display, Why, 8]).

%% A stop of row Name answers each start of it waiting on a display with ok,
%% as the stop leaves the row, and the start does not follow.
unwait(Name, #{displays := Displays} = State) ->
    Unwaited = fun(_Display, {Request, Waiting}) ->
                       {Stopped, Others} = lists:partition(fun({Waiter, _Reply}) -> Waiter =:= Name end, Waiting),
                       lists:foreach(fun({_Waiter, Reply}) -> answer(Reply, ok) end, Stopped),
                       {Request, Others}
               end,
    State#{displays := maps:map(Unwaited, Displays)}.

started({ok, _Pid}) -> ok;
started({error, {already_started, _}}) -> ok;
started({error, Why}) -> {error, {failed, Why}}.

%% What enabled row Name's supervisor keeps (erx_starter_row:row()), or none
%% for a row that is not enabled.
row(Name, #{merged := Merged} = State) when is_list(Merged) ->
    case [Row || #{principal := Principal, status := enabled} = Row <- Merged, Principal =:= Name] of
        [#{display := Display, restarts := Restarts, period := Period}] ->
            Start = case Display of
                        none -> with_default_display(Name, #{}, State);
                        _ -> #{display => Display}
                    end,
            {ok, #{principal => who(Name, State), start => Start, restarts => Restarts, period => Period}};
        [] ->
            none
    end;
row(_Name, #{merged := none}) ->
    none.

%% Whose session row Name keeps (erx_starter_keeper): a manifest principal's
%% number, or the app's of that name, since admission refuses an app a manifest
%% principal's name (docs/design-packaging.md, "Admission").
who(Name, #{principals := Principals}) ->
    case Principals of
        #{Name := Number} -> Number;
        #{} -> {app, Name}
    end.

%% Start for row Name's session, which names a display or names none: with none, the one
%% display Name's template is granted, where it is granted exactly one, as the session's
%% default display, so an app written for one display runs on any board
%% (docs/design-display.md, "Choosing a display"). The start table is the one place a
%% template's displays are worked out (manifest_table/1); the domain service applies none
%% of its own, so a console login, which no row starts, has no default display.
with_default_display(Name, Start, State) when map_size(Start) =:= 0 ->
    {_Rows, Grants} = rows_and_grants(State),
    case maps:get(Name, Grants, []) of
        [Display] -> #{default_display => Display};
        _ -> Start
    end;
with_default_display(_Name, Start, _State) ->
    Start.

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
