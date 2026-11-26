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
  or the first failure.
""".

-behaviour(gen_server).

-export([medium/1, eject/1, freeze/1, start_link/2]).
-export_type([medium/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% How long an ask waits on the facet: the grant's own wait for a medium's end,
%% erx_blk_drive's CALL_TIMEOUT.
-define(ASK_TIMEOUT, 60000).

-type medium() :: #{proxy := pid(), table := erx_media_medium:table() | ejected}.

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
handle_call(eject, _From, #{medium := #{sup := Sup, table := {_Scheme, Volumes, _Unserved}} = Held} = State)
  when is_pid(Sup) ->
    Answer = finish(Volumes),
    stop(Sup),
    {reply, Answer, State#{medium := Held#{table := ejected, sup := none}}};
handle_call(eject, _From, State) ->
    {reply, {error, enxio}, State};
handle_call(freeze, _From, #{medium := #{sup := Sup, table := {_Scheme, Volumes, _Unserved}}} = State)
  when is_pid(Sup) ->
    {reply, finish(Volumes), State};
handle_call(freeze, _From, State) ->
    {reply, ok, State};
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

-doc false.
handle_cast(_Other, State) ->
    {noreply, State}.

%% The proxy's end is the medium's, and its supervisor's.
-doc false.
handle_info({'DOWN', Monitor, process, _Proxy, _Reason}, #{medium := #{monitor := Monitor, sup := Sup}} = State) ->
    stop(Sup),
    {noreply, State#{medium := none}};
handle_info(_Other, State) ->
    {noreply, State}.

%% The medium behind Proxy as the drive process holds it: the proxy monitored, its
%% table read, and the supervisor of its volumes, or none for a medium left idle, whose
%% supervisor is stopped with any volume a failed reading had started.
held(Proxy) ->
    Monitor = monitor(process, Proxy),
    {ok, Sup} = erx_media_medium:start_link(),
    Table = erx_media_medium:read(Sup, Proxy),
    Served = case Table of
                 {_Scheme, _Volumes, _Unserved} -> Sup;
                 _Idle -> stop(Sup), none
             end,
    #{proxy => Proxy, table => Table, monitor => Monitor, sup => Served}.

answer(Held) -> maps:with([proxy, table], Held).

%% Every volume of a medium's table sent its finish at once, and the first failure of
%% their answers, or ok.
finish(Volumes) ->
    first_failure(answers([gen_server:send_request(Pid, finish) || {_Volume, Pid} <- Volumes, is_pid(Pid)])).

%% Each request's answer, eio for a process that ended before it answered.
answers(Requests) ->
    [case gen_server:receive_response(Request, infinity) of
         {reply, Answer} -> Answer;
         {error, {_Reason, _Server}} -> {error, eio}
     end || Request <- Requests].

first_failure(Answers) ->
    case [Failed || Failed <- Answers, Failed =/= ok] of
        [] -> ok;
        [{error, Reason} | _] when is_atom(Reason) -> {error, Reason};
        [_Malformed | _] -> {error, eio}
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
