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

The medium's supervisor, its reader and volumes, and the media tree whose walk of
`diskN` makes the ask are not built yet (docs/todo-storage.md, step 4); medium/1 is that
ask.
""".

-behaviour(gen_server).

-export([medium/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% How long an ask waits on the facet: the grant's own wait for a medium's end,
%% erx_blk_drive's CALL_TIMEOUT.
-define(ASK_TIMEOUT, 60000).

-doc """
The medium of the drive the registry holds as `{drive, N}`: `{ok, Proxy}`, or
`{error, no_medium}`; `{error, no_drive}` while the registry holds no such drive, for
which no drive process starts.
""".
-spec medium(non_neg_integer()) -> {ok, pid()} | {error, no_medium | no_drive}.
medium(N) when is_integer(N), N >= 0 ->
    case erx:cap({drive, N}) of
        undefined -> {error, no_drive};
        _Facet -> gen_server:call(erx_media_sup:drive(N), medium, infinity)
    end.

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
handle_call(medium, _From, #{medium := {Proxy, _Monitor}} = State) ->
    {reply, {ok, Proxy}, State};
handle_call(medium, _From, #{find := Find} = State) ->
    case ask(Find()) of
        {ok, Proxy} -> {reply, {ok, Proxy}, State#{medium := {Proxy, monitor(process, Proxy)}}};
        no_medium -> {reply, {error, no_medium}, State}
    end;
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

-doc false.
handle_cast(_Other, State) ->
    {noreply, State}.

%% The proxy's end is the medium's.
-doc false.
handle_info({'DOWN', Monitor, process, _Proxy, _Reason}, #{medium := {_, Monitor}} = State) ->
    {noreply, State#{medium := none}};
handle_info(_Other, State) ->
    {noreply, State}.

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
