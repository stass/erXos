%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_drive).
-moduledoc """
A drive grant (docs/design-drives.md, "A drive and its medium";
docs/design-usb.md, "Mass storage reaches the file servers"): the process
that hands a drive's holder, the media domain, the window over whatever
medium the drive holds now, whole. It is made for one drive row and lives
as long as the domain that serves the drive's media, which reaches it by
pid and never registers it. It checks no caller: holding the grant is
holding the drive's medium, as holding a window is holding its sectors.

It answers one request, window/1: `{ok, Window}`, the pid of the medium's
window, or `{error, no_medium}` while the drive holds none. It learns of
each window from the medium's block service, which calls serve/3 as the
window starts, and forgets it when it sees that window end.

**Asked again.** The first ask for a window answers it. A later ask comes
only from a holder that restarted and lost the window, whose earlier
mount may still have requests on their way, so the grant first ends the
medium's block service: it sends the medium's issuer, the one process
that issues the medium's commands, `{erx_blk_drive, end_medium, Medium}`,
with the Medium term the block service gave serve/3. The issuer makes the
medium's reference stale in one step, so every request of the old window,
queued or arriving later, is refused unissued, and the old window ends;
a request it had already issued completes before any command of a next
medium, which it issues only behind it. On USB the window ends at once
and the issued command finishes later, ahead of the next medium's
readiness in the engine's one queue. The grant holds every ask until it
sees that window end, then answers what it holds: the window of the
medium's next block service if one has started by then, under a fresh
reference, or `{error, no_medium}`, after which the holder's next ask
finds the medium once it is ready (on USB it may come back as another
drive). So an earlier mount's requests are answered, or refused
unissued, before a new mount can send its first.

Its decisions are the pure step/2, over three events (an ask, a window
served, a window ended) and two actions (an answer, an end of a medium);
this module's process performs them. It monitors each window it is told
of and knows a window's end only by that monitor's reference, so no
message another process makes up ends a medium in its eyes.
""".

-behaviour(gen_server).

-export([start_link/0, window/1, serve/3]).
-export([new/0, step/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([state/0, event/0, action/0, issuer/0]).

%% A holder whose ask waits on an end longer than this sees no medium and asks again at
%% its next walk.
-define(CALL_TIMEOUT, 60000).

-doc "How a medium is ended: the issuing process, and the term it is sent to name the medium.".
-type issuer() :: {pid(), term()}.

-doc """
The grant's state: the drive's medium, none or its window, the monitor of
that window, its issuer and whether a holder was handed the window; the
monitor of the window whose end the grant asked for and waits on, or
none; and the asks held meanwhile, oldest first.
""".
-type state() :: #{medium := none | #{window := pid(), monitor := reference(), issuer := issuer(),
                                      answered := boolean()},
                   ending := none | reference(),
                   asks := [gen_server:from()]}.
-type event() :: {ask, gen_server:from()} | {serve, pid(), reference(), issuer()} | {ended, reference()}.
-type action() :: {answer, gen_server:from(), {ok, pid()} | {error, no_medium}} | {end_medium, issuer()}.

-doc "Starts a grant, linked to the caller, which knows of no medium yet.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-doc """
The window over the medium Grant's drive holds now, or no_medium; also
no_medium when the grant is gone or does not answer in time.
""".
-spec window(pid()) -> {ok, pid()} | {error, no_medium}.
window(Grant) ->
    try gen_server:call(Grant, window, ?CALL_TIMEOUT) catch exit:_ -> {error, no_medium} end.

-doc """
Tells Grant that the drive's medium is served by Window, and that the
grant ends it by sending Issuer `{erx_blk_drive, end_medium, Medium}`.
The medium's block service calls it as the window starts. It waits on
nothing, so a grant that is gone or slow holds up no medium's issuer.
""".
-spec serve(pid(), pid(), issuer()) -> ok.
serve(Grant, Window, Issuer = {IssuerPid, _Medium}) when is_pid(Window), is_pid(IssuerPid) ->
    gen_server:cast(Grant, {serve, Window, Issuer}).

%% ---------------------------------------------------------------------------
%% The pure core
%% ---------------------------------------------------------------------------

-doc "A grant that knows of no medium.".
-spec new() -> state().
new() ->
    #{medium => none, ending => none, asks => []}.

-doc """
The grant's next state on Event, and its actions in order. While the
grant waits on a window's end it answers no ask; the end answers every
ask it held at once, from the medium it holds then.
""".
-spec step(event(), state()) -> {state(), [action()]}.
step({ask, From}, State = #{ending := Ending, asks := Asks}) when Ending =/= none ->
    {State#{asks := Asks ++ [From]}, []};
step({ask, From}, State = #{medium := none}) ->
    {State, [{answer, From, {error, no_medium}}]};
step({ask, From}, State = #{medium := Medium = #{window := Window, answered := false}}) ->
    {State#{medium := Medium#{answered := true}}, [{answer, From, {ok, Window}}]};
step({ask, From}, State = #{medium := #{monitor := Monitor, issuer := Issuer, answered := true}}) ->
    {State#{ending := Monitor, asks := [From]}, [{end_medium, Issuer}]};
step({serve, Window, Monitor, Issuer}, State) ->
    {State#{medium := #{window => Window, monitor => Monitor, issuer => Issuer, answered => false}}, []};
step({ended, Monitor}, State = #{medium := Medium, ending := Ending}) ->
    Forgotten = case Medium of
                    #{monitor := Monitor} -> State#{medium := none};
                    _NoneOrOther -> State
                end,
    case Ending of
        Monitor -> answer_held(Forgotten#{ending := none});
        _NoneOrAnother -> {Forgotten, []}
    end.

%% Every held ask answered from the medium held now, which they are then handed.
answer_held(State = #{medium := none, asks := Asks}) ->
    {State#{asks := []}, [{answer, From, {error, no_medium}} || From <- Asks]};
answer_held(State = #{medium := Medium = #{window := Window}, asks := Asks}) ->
    {State#{medium := Medium#{answered := true}, asks := []}, [{answer, From, {ok, Window}} || From <- Asks]}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

-doc false.
init([]) ->
    {ok, new()}.

-doc false.
handle_call(window, From, State) ->
    perform(step({ask, From}, State));
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

-doc false.
handle_cast({serve, Window, Issuer = {IssuerPid, _Medium}}, State) when is_pid(Window), is_pid(IssuerPid) ->
    perform(step({serve, Window, monitor(process, Window), Issuer}, State));
handle_cast(_Other, State) ->
    {noreply, State}.

%% A window's end, known only by the monitor the grant made for it.
-doc false.
handle_info({'DOWN', Monitor, process, _Window, _Reason}, State) ->
    perform(step({ended, Monitor}, State));
%% A stray message is dropped unlogged, so no sender fills the log with terms it chose.
handle_info(_Other, State) ->
    {noreply, State}.

perform({State, Actions}) ->
    lists:foreach(fun act/1, Actions),
    {noreply, State}.

act({answer, From, Reply}) ->
    gen_server:reply(From, Reply);
act({end_medium, {Issuer, Medium}}) ->
    Issuer ! {?MODULE, end_medium, Medium}.
