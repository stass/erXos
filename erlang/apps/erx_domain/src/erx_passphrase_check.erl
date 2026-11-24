%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_passphrase_check).
-moduledoc """
The principal service's one passphrase check, backed before the vault by the
development checker (docs/design-login.md, "The passphrase check", and
decision 1).

* **Release builds.** In a build that is not a development build
  (erx_build:development/0) every check answers `unavailable` and nothing is
  read.
* **Limits.** erx_passphrase_limits counts failures by name and by terminal;
  a check it limits answers `limited` with no derivation.
* **One derivation at a time.** Checks wait in one queue, the limits applied
  as each leaves it, and one worker process at a time reads root's record and
  derives. A worker that ends without an answer, or is killed at its
  deadline, answers `unavailable` and counts nothing.
* **The same answer for a stranger.** The worker reads root's record for
  every check and derives under its salt and rounds whatever the name; only
  `root` with a matching hash answers `match`, and every other name
  `no_match`. A record that is absent, unread or malformed answers
  `unavailable` to every name.
* **Secrets.** A check is a message to an alias, never a gen_server call, so no
  exit of the caller's wait carries the request. The server sets
  `process_flag(sensitive, true)` before it registers its name, each worker
  before it reads, the worker catches every exception, so no crash report
  carries a passphrase, and format_status/1 shows only the queue's length, the
  number of counters and whether a worker runs.
""".

-behaviour(gen_server).

-export([start_link/0, start_link/1, check/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).
-export_type([answer/0, options/0]).

-define(ROOT, <<"root">>).
-define(RECORD_FILE, <<"root_passphrase">>).
-define(NAME_MAX, 255).
-define(PASSPHRASE_MAX, 256).
%% How long one worker may read and derive: a derivation at the most rounds, and
%% the storage domain's reader of a medium that is slow to answer.
-define(WORKER_MS, 30000).
%% How often a worker asks again while the tree answers eagain.
-define(EAGAIN_MS, 100).

-doc "A check's answer.".
-type answer() :: match | no_match | limited | unavailable | badarg.

-doc """
What the checker runs on: whether the build is a development build, the read
of root's record, the clock in milliseconds, and a worker's deadline.
""".
-type options() :: #{development := boolean(),
                     read := fun(() -> {ok, binary()} | {error, term()}),
                     now := fun(() -> integer()),
                     worker_ms => pos_integer()}.

-doc "Starts the checker of this build, reading root's record through the system domain's grant.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{development => erx_build:development(), read => fun read_record/0,
                 now => fun() -> erlang:monotonic_time(millisecond) end}).

-doc "Starts the checker on `Options`; it registers its name once it is sensitive.".
-spec start_link(options()) -> {ok, pid()} | {error, term()}.
start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

-doc """
Checks `Passphrase` for `Name`, given at `Terminal` in the network class, the
only class a front end's login has. A checker that is not running, or ends
before it answers, answers `unavailable`.
""".
-spec check(network, binary(), binary(), term()) -> answer().
check(network, Name, Passphrase, Terminal) ->
    case whereis(?MODULE) of
        undefined ->
            unavailable;
        Server ->
            Alias = erlang:monitor(process, Server, [{alias, reply_demonitor}]),
            Server ! {?MODULE, check, Alias, Name, Passphrase, Terminal},
            receive
                {Alias, Answer} -> Answer;
                {'DOWN', Alias, process, _, _} -> unavailable
            end
    end.

-doc false.
init(Options) ->
    process_flag(sensitive, true),
    true = register(?MODULE, self()),
    {ok, maps:merge(#{worker_ms => ?WORKER_MS}, Options#{counts => erx_passphrase_limits:new(),
                                                        queue => queue:new(), busy => none})}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, badarg, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
handle_info({?MODULE, check, Alias, _Name, _Passphrase, _Terminal}, #{development := false} = State) ->
    Alias ! {Alias, unavailable},
    {noreply, State};
handle_info({?MODULE, check, Alias, Name, Passphrase, Terminal}, #{queue := Queue} = State)
  when is_reference(Alias), is_binary(Name), byte_size(Name) >= 1, byte_size(Name) =< ?NAME_MAX,
       is_binary(Passphrase), byte_size(Passphrase) >= 1, byte_size(Passphrase) =< ?PASSPHRASE_MAX ->
    {noreply, next(State#{queue := queue:in({Alias, Name, Passphrase, Terminal}, Queue)})};
handle_info({?MODULE, check, Alias, _Name, _Passphrase, _Terminal}, State) when is_reference(Alias) ->
    Alias ! {Alias, badarg},
    {noreply, State};
handle_info({'DOWN', Monitor, process, _Worker, Reason}, #{busy := {Monitor, _, Timer, Alias, Name, Terminal}} = State) ->
    _ = erlang:cancel_timer(Timer),
    Answer = case Reason of
                 {?MODULE, Answered} when Answered =:= match; Answered =:= no_match; Answered =:= unavailable -> Answered;
                 _ -> unavailable
             end,
    Alias ! {Alias, Answer},
    {noreply, next(counted(Answer, Name, Terminal, State#{busy := none}))};
handle_info({?MODULE, deadline, Monitor}, #{busy := {Monitor, Worker, _, _, _, _}} = State) ->
    exit(Worker, kill),
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun(#{queue := Queue, counts := Counts, busy := Busy}) ->
                                                  #{queued => queue:len(Queue),
                                                    counters => erx_passphrase_limits:size(Counts),
                                                    deriving => Busy =/= none}
                                          end}).

%% Starts the next check of the queue when no worker runs. A check its counters
%% limit is answered at once, with no derivation, and the next one taken.
next(#{busy := none, queue := Queue, counts := Counts, now := Now, read := Read, worker_ms := Deadline} = State) ->
    case queue:out(Queue) of
        {empty, _} ->
            State;
        {{value, {Alias, Name, Passphrase, Terminal}}, Rest} ->
            case erx_passphrase_limits:admit(Name, Terminal, Now(), Counts) of
                limited ->
                    Alias ! {Alias, limited},
                    next(State#{queue := Rest});
                ok ->
                    {Worker, Monitor} = spawn_monitor(fun() -> worker(Read, Name, Passphrase) end),
                    Timer = erlang:send_after(Deadline, self(), {?MODULE, deadline, Monitor}),
                    State#{queue := Rest, busy := {Monitor, Worker, Timer, Alias, Name, Terminal}}
            end
    end;
next(State) ->
    State.

counted(no_match, Name, Terminal, #{counts := Counts, now := Now} = State) ->
    State#{counts := erx_passphrase_limits:failed(Name, Terminal, Now(), Counts)};
counted(_Answer, _Name, _Terminal, State) ->
    State.

%% The worker ends with its answer as its exit reason, which only the server's
%% monitor receives. It catches every exception, so its end never logs a report
%% that could quote the passphrase.
worker(Read, Name, Passphrase) ->
    process_flag(sensitive, true),
    Answer = try derived(settled(Read), Name, Passphrase) catch _:_ -> unavailable end,
    exit({?MODULE, Answer}).

%% The tree answers eagain until the storage domain's reader is done, so the first
%% check of a boot asks again; the server's deadline bounds the wait.
settled(Read) ->
    case Read() of
        {error, eagain} -> timer:sleep(?EAGAIN_MS), settled(Read);
        Other -> Other
    end.

%% Every name derives under root's record, so the work is the same whatever the name.
derived({ok, Bytes}, Name, Passphrase) ->
    case erx_passphrase_hash:decode(Bytes) of
        {ok, Record} -> answer(Name, erx_passphrase_hash:matches(Passphrase, Record));
        {error, malformed} -> unavailable
    end;
derived(_Unread, _Name, _Passphrase) ->
    unavailable.

answer(?ROOT, true) -> match;
answer(_Name, _Matched) -> no_match.

%% Root's record through the system domain's grant of login_keys, at most one byte
%% past the largest record, without read-ahead.
read_record() ->
    Max = erx_passphrase_hash:record_max() + 1,
    case erx_facets:file_grant(login_keys, ro) of
        {ok, Grant} ->
            case erx_file_remote:open(Grant, {target, [?RECORD_FILE]}, [read, binary]) of
                {ok, Fd} -> try read_at_most(Fd, Max, []) after file:close(Fd) end;
                {error, eagain} = Error -> Error;
                _ -> {error, unopened}
            end;
        {error, _} = Error ->
            Error
    end.

read_at_most(_Fd, 0, Read) ->
    {ok, iolist_to_binary(lists:reverse(Read))};
read_at_most(Fd, Left, Read) ->
    case file:read(Fd, Left) of
        {ok, Bytes} when byte_size(Bytes) =< Left -> read_at_most(Fd, Left - byte_size(Bytes), [Bytes | Read]);
        eof -> {ok, iolist_to_binary(lists:reverse(Read))};
        {error, eagain} = Error -> Error;
        _ -> {error, unread}
    end.
