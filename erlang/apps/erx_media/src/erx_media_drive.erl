%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_drive).
-moduledoc """
A drive process (docs/design-drives.md, "One path from medium to files" and
"Concurrency"): the media domain's one process for the drive its registry holds as
`{drive, N}`, under erx_media_sup. It reads no sector.

At each ask for the medium it answers the medium it holds, or asks the drive's facet,
which Find reads from the registry at that ask, for `window`. The facet's
`{ok, Proxy}` is the medium: a window proxy of the serving domain, which takes the
medium's `{read, Sector, Count}`, `{write, Sector, Bytes}`, `flush` and `info` under the
grant's limits (erx_blk_drive_proxy), and which the drive process monitors. Any other
answer, the facet's `{error, busy}` and `{error, failed}` among them, a facet the
registry does not hold, or no answer within the grant's own 60 s, is no medium at that
ask. The proxy's end is the medium's end, whether the window ended or the proxy did,
and the next ask asks again, which the grant answers by ending the medium's block
service first, so a restarted drive process starts with no earlier request outstanding.

At an ask that gets a proxy, the drive process starts the medium's supervisor,
erx_media_medium, linked to it, and waits for its reader to read the table and start
the volume processes ("Reading a medium"), so the answer that follows names every
volume. A table refused or a reading that failed leaves the medium idle: held, with
no volume, until its proxy ends. The proxy's end ends the supervisor, and every volume
of the medium with it. The media tree's walk of `diskN` makes the ask, medium/1.

Two requests finish a medium's volumes ("Finishing a volume"), each sending every
volume its finish at once and waiting for each answer, while asks of the drive wait
behind it:

* eject/1, a write of `eject` to the drive's `ctl`, then ends the medium's supervisor
  and holds the medium idle as ejected, its table `ejected`, until its proxy ends, so
  an ejected medium mounts again only once it has ended. It answers `ok` when every
  finish answered `ok`, `eio` when one did not or its volume had already ended, the
  medium ended either way, and `enxio` when the drive holds no mounted medium.
* freeze/1, the media service's part of the ordered end, finishes every volume of
  every drive it names and keeps each medium as it is; it answers `ok` once all have,
  or the first failure. An eject after it finds every volume already finished, and so
  answers `eio`; the ordered end that freezes ejects nothing.
""".

-behaviour(gen_server).

-export([medium/1, raw/1, eject/1, freeze/1, start_link/2]).
-export_type([medium/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% How long an ask waits on the facet: the grant's own wait for a medium's end,
%% erx_blk_drive's CALL_TIMEOUT.
-define(ASK_TIMEOUT, 60000).

%% The table as a walk sees it: raw while the raw process holds the whole medium, and raw
%% in place of a volume's process while the raw process holds that volume.
-type medium() :: #{proxy := pid(), table := erx_media_medium:table() | ejected | raw}.

-doc """
The medium of the drive the registry holds as `{drive, N}`: `{ok, Medium}`, its window
proxy and the table its reader answered, every served volume started; or
`{error, no_medium}`; `{error, no_drive}` while the registry holds no such drive, for
which no drive process starts.
""".
-spec medium(non_neg_integer()) -> {ok, medium()} | {error, no_medium | no_drive}.
medium(N) when is_integer(N), N >= 0 ->
    case erx:cap({drive, N}) of
        undefined -> {error, no_drive};
        _Facet -> gen_server:call(erx_media_sup:drive(N), medium, infinity)
    end.

-doc """
Ejects the medium of the drive the registry holds as `{drive, N}`: `ok`, `{error, eio}`
or `{error, enxio}` as the module's description gives, `enxio` too while the registry
holds no such drive.
""".
-spec eject(non_neg_integer()) -> ok | {error, eio | enxio}.
eject(N) when is_integer(N), N >= 0 ->
    case erx:cap({drive, N}) of
        undefined -> {error, enxio};
        _Facet -> gen_server:call(erx_media_sup:drive(N), eject, infinity)
    end.

-doc """
Finishes every mounted volume of the drive processes Drives at once: `ok` once every
finish answered `ok`, else the first failure, `eio` for a drive process or a volume
that has ended.
""".
-spec freeze([pid()]) -> ok | {error, atom()}.
freeze(Drives) ->
    first_failure(answers([gen_server:send_request(Drive, freeze) || Drive <- Drives])).

-doc """
Starts the drive process of drive N, linked to the caller, erx_media_sup. Find answers
the drive's facet as the registry holds it at the call, or `undefined`.
""".
-spec start_link(non_neg_integer(), fun(() -> pid() | undefined)) -> {ok, pid()}.
start_link(N, Find) when is_integer(N), N >= 0, is_function(Find, 0) ->
    gen_server:start_link(?MODULE, Find, []).

-doc """
The raw process of drive N's medium (erx_media_raw), started under the medium's
supervisor at the first ask: `{ok, Raw}`, or `{error, enoent}` while the drive holds no
medium whose sectors are served (none, ejected, or ended `idle failed`).
""".
-spec raw(non_neg_integer()) -> {ok, pid()} | {error, enoent | eio}.
raw(N) when is_integer(N), N >= 0 ->
    case erx:cap({drive, N}) of
        undefined -> {error, enoent};
        _Facet -> gen_server:call(erx_media_sup:drive(N), raw, infinity)
    end.

-doc false.
init(Find) ->
    {ok, #{find => Find, medium => none}}.

-doc false.
handle_call(medium, _From, #{medium := #{} = Held} = State) ->
    {reply, {ok, answer(Held)}, State};
handle_call(medium, _From, #{find := Find} = State) ->
    case ask(Find()) of
        {ok, Proxy} ->
            Held = held(Proxy),
            {reply, {ok, answer(Held)}, State#{medium := Held}};
        no_medium ->
            {reply, {error, no_medium}, State}
    end;
handle_call(raw, _From, #{medium := #{sup := Sup} = Held} = State) when is_pid(Sup) ->
    case started_raw(Held) of
        {ok, Raw, Held1} -> {reply, {ok, Raw}, State#{medium := Held1}};
        {error, _} = Refused -> {reply, Refused, State}
    end;
handle_call(raw, _From, State) ->
    {reply, {error, enoent}, State};
handle_call(eject, _From, #{medium := #{sup := Sup} = Held} = State) when is_pid(Sup) ->
    Answer = finish(Held, eio),
    {reply, Answer, State#{medium := ended(Held, ejected)}};
handle_call(eject, _From, State) ->
    {reply, {error, enxio}, State};
handle_call(freeze, _From, #{medium := #{sup := Sup} = Held} = State) when is_pid(Sup) ->
    {reply, finish(Held, erofs), State};
handle_call(freeze, _From, State) ->
    {reply, ok, State};
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

-doc false.
handle_cast(_Other, State) ->
    {noreply, State}.

%% The raw process's take and hand-back, taken in the order it sent them. A take answers
%% what it took out of service, which the raw process holds whatever the answer.
-doc false.
handle_info({raw_take, Raw, Open, Cover}, #{medium := #{raw := {Raw, _}} = Held} = State) ->
    {Took, Answer, Held1} = taken(Cover, Held),
    Raw ! {raw_took, Open, Took, Answer},
    {noreply, State#{medium := Held1}};
handle_info({raw_take, Raw, Open, _Cover}, State) ->
    Raw ! {raw_took, Open, [], {error, eio}},
    {noreply, State};
handle_info({raw_hand_back, Raw, Covers}, #{medium := #{raw := {Raw, _}} = Held} = State) ->
    {noreply, State#{medium := handed_back(Covers, Held)}};
%% The raw process's end: the end of the medium while it holds anything.
handle_info({'DOWN', Monitor, process, _Raw, Why}, #{medium := #{raw := {_, Monitor}} = Held} = State) ->
    case Held of
        #{taken := []} -> {noreply, State#{medium := Held#{raw := none}}};
        #{} -> {noreply, State#{medium := ended(Held#{raw := none}, {failed, {raw, Why}})}}
    end;
%% The proxy's end is the medium's, and its supervisor's.
handle_info({'DOWN', Monitor, process, _Proxy, _Reason}, #{medium := #{monitor := Monitor} = Held} = State) ->
    _ = ended(Held, ejected),
    {noreply, State#{medium := none}};
handle_info(_Other, State) ->
    {noreply, State}.

%% The medium behind Proxy as the drive process holds it: the proxy monitored, its
%% table read, and the supervisor of its volumes, kept for a table refused, whose raw
%% sectors are still served, and started afresh, with no volume, for a reading that
%% failed, whose volumes may still run. No raw process runs yet and nothing is taken.
held(Proxy) ->
    Monitor = monitor(process, Proxy),
    {ok, Sup} = erx_media_medium:start_link(),
    Table = erx_media_medium:read(Sup, Proxy),
    Served = case Table of
                 {failed, _Why} -> stop(Sup), {ok, Empty} = erx_media_medium:start_link(), Empty;
                 _Read -> Sup
             end,
    #{proxy => Proxy, table => Table, monitor => Monitor, sup => Served, raw => none, taken => []}.

%% The medium as a walk sees it: the whole medium taken shows as the table raw, with no
%% volume; a volume taken shows raw in its process's place.
answer(#{taken := Taken} = Held) ->
    #{proxy := Proxy, table := Table} = Held,
    #{proxy => Proxy, table => shown(Table, Taken)}.

shown(_Table, [medium | _]) ->
    raw;
shown({Scheme, Volumes, Unserved}, Taken) ->
    {Scheme, [{V, case lists:member({volume, N}, Taken) of true -> raw; false -> P end}
              || {#{number := N} = V, P} <- Volumes], Unserved};
shown(Table, _Taken) ->
    Table.

%% The served volumes of the held medium by number, each with its process.
volumes(#{table := {_Scheme, Volumes, _Unserved}}) ->
    [{N, Volume, Pid} || {#{number := N} = Volume, Pid} <- Volumes, is_pid(Pid)];
volumes(#{}) ->
    [].

%% The raw process, started now if none runs. The volumes it serves are every volume the
%% table lists but an extended entry.
started_raw(#{raw := {Raw, _}} = Held) ->
    {ok, Raw, Held};
started_raw(#{sup := Sup, proxy := Proxy, table := Table} = Held) ->
    Volumes = case Table of
                  {_Scheme, Listed, _Unserved} -> [V || {V, P} <- Listed, P =/= extended];
                  _Refused -> []
              end,
    Spec = #{id => raw, start => {erx_media_raw, start_link, [self(), Proxy, Volumes]}, restart => temporary},
    case supervisor:start_child(Sup, Spec) of
        {ok, Raw} -> {ok, Raw, Held#{raw := {Raw, monitor(process, Raw)}}};
        {error, _Why} -> {error, eio}
    end.

%% What a take of Cover finishes: volume N, or every volume, less what the raw process
%% already holds. Each volume finished is taken, a failed finish included.
taken(Cover, #{taken := Taken} = Held) ->
    Finished = [{N, Pid} || {N, _Volume, Pid} <- volumes(Held), not lists:member({volume, N}, Taken),
                            Cover =:= medium orelse Cover =:= {volume, N}],
    Answer = first_failure(answers([gen_server:send_request(Pid, finish) || {_N, Pid} <- Finished])),
    Took = [{volume, N} || {N, _Pid} <- Finished] ++ [medium || Cover =:= medium],
    [logger:notice("erx_media: ~s taken out of service for raw access", [taken_name(Cover)]) || Took =/= []],
    {Took, Answer, Held#{taken := lists:usort(Taken ++ Took)}}.

taken_name(medium) -> "the medium";
taken_name({volume, N}) -> io_lib:format("volume s~b", [N]).

%% Covers handed back: the whole medium mounts afresh, its table read again; a volume
%% starts a new process under the medium's supervisor.
handed_back(Covers, #{proxy := Proxy, monitor := Monitor, raw := {_Raw, RawMonitor}} = Held) ->
    case lists:member(medium, Covers) of
        true ->
            demonitor(RawMonitor, [flush]),
            _ = ended(Held, ejected),
            demonitor(Monitor, [flush]),
            held(Proxy);
        false ->
            lists:foldl(fun volume_returned/2, Held, Covers)
    end.

volume_returned({volume, N}, #{sup := Sup, proxy := Proxy, table := {Scheme, Volumes, Unserved}, taken := Taken} = Held) ->
    [Volume] = [V || {#{number := Number} = V, _P} <- Volumes, Number =:= N],
    {ok, Pid} = erx_media_medium:restart_volume(Sup, Proxy, Volume),
    Returned = [case Number of N -> {V, Pid}; _ -> {V, P} end || {#{number := Number} = V, P} <- Volumes],
    Held#{table := {Scheme, Returned, Unserved}, taken := lists:delete({volume, N}, Taken)}.

%% Every volume not taken and the raw process, if it runs, sent their finish at once,
%% the raw process's naming the errno its later requests answer; the first failure of
%% their answers, or ok.
finish(#{raw := Raw, taken := Taken} = Held, Errno) ->
    Volumes = [gen_server:send_request(Pid, finish) || {N, _V, Pid} <- volumes(Held), not lists:member({volume, N}, Taken)],
    Raws = [gen_server:send_request(Pid, {finish, Errno}) || {Pid, _Monitor} <- [Raw || Raw =/= none]],
    first_failure(answers(Volumes ++ Raws)).

%% The medium's supervisor ended, and the medium held idle with Table, until its proxy
%% ends; the raw process's monitor dropped first, so its end is not taken as a failure.
ended(#{sup := Sup, raw := Raw} = Held, Table) ->
    [demonitor(Monitor, [flush]) || {_Pid, Monitor} <- [Raw || Raw =/= none]],
    stop(Sup),
    Held#{table := Table, sup := none, raw := none, taken := []}.

%% Each request's answer, eio for a process that ended before it answered.
answers(Requests) ->
    [case gen_server:receive_response(Request, infinity) of
         {reply, Answer} -> Answer;
         {error, {_Reason, _Server}} -> {error, eio}
     end || Request <- Requests].

first_failure(Answers) ->
    case [Failed || {error, _} = Failed <- Answers] of
        [] -> ok;
        [First | _] -> First
    end.

%% Stops the medium's supervisor Sup, which ends its volumes, unlinked first so that its
%% end is not the drive process's; an idle medium has none.
stop(none) ->
    ok;
stop(Sup) ->
    unlink(Sup),
    ok = proc_lib:stop(Sup, shutdown, infinity).

%% The facet's answer to `window`: a proxy, or no medium. A late answer after the
%% timeout goes to an alias that has ended, which delivers nothing.
ask(Facet) when is_pid(Facet) ->
    try gen_server:call(Facet, window, ?ASK_TIMEOUT) of
        {ok, Proxy} when is_pid(Proxy) -> {ok, Proxy};
        _Other -> no_medium
    catch
        exit:_Reason -> no_medium
    end;
ask(undefined) ->
    no_medium.
