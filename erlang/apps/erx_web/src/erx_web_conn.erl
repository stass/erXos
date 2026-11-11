%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_conn).
-moduledoc """
One browser connection of the web front end (docs/design-web.md, "The
connection core"): a pure state machine that both front ends drive, so
they differ in how bytes arrive and leave and in nothing else (W5).
step/2 takes one input and returns the actions its driver performs, in
order, and the next state; it sends nothing and reads no clock.

* The first message must be a `hello` with erx_web_proto's hash. Another
  hash closes with `bye mismatch`. A message the codec refuses, a text
  message, a second `hello`, and anything before `hello` close with `bye
  protocol`; so does a request no correct client sends: a `next` while the
  view's last request is unanswered, a `next`, `close` or `event` for a
  number above every one opened, and an `event` for a view that is not a
  UI. A number below that which names no open view is dropped.
* View numbers only grow. An `open` must name a number above every number
  the connection opened before, which is how "never reused" holds without
  remembering them, and an `open` of the last u32 closes with `bye limit`
  before the numbers wrap. An open beyond the 16 views a connection holds
  is answered `ended busy` and uses its number.
* A view is asked for one update by its `open` and for one more by each
  `next`, and the core sends each answer as one `update`. An answer nobody
  asked for, or for a view that is gone, is dropped, never kept: a source
  that changes faster than the browser reads is sampled by its view, and
  the core holds no update between steps. A `next`, `close` or `event` for
  a view that is gone is dropped, since its `ended` may be on its way.
* A view the browser closes before the front end reports its pid stays
  `closing`, counted among the 16, until the pid arrives and is stopped,
  so no view process outlives its connection and the bound holds while a
  view is starting. A view that reports its own end is stopped as well,
  and closing the connection stops every view it holds.

The driver answers every `open` action with exactly one `opened`, or with
`ended` when the view could not start (the line's `{error, busy}`), and
counts refusals by the reason of the `close` action.

What a connection holds is bounded and declared: at most 16 views of one
small record each, the encoded `welcome` and the highest view number. Its
updates pass through and are never stored.
""".

-export([new/1, step/2, perform/2]).
-export_type([state/0, input/0, action/0]).

-type view() :: erx_web_proto:view().
-type target() :: erx_web_proto:target().
-type close_reason() :: mismatch | protocol | limit | idle.

-type input() :: {in, binary()}                  % a binary WebSocket message
               | {text, binary()}                % a text WebSocket message
               | {opened, view(), pid()}         % the view's process, once perform/2 has it
               | {update, view(), erx_web_proto:body()}
               | {ended, view(), atom() | binary()}  % the view, or what it shows, is over
               | tick.                           % web_idle_ms passed with no frame from the browser

-type action() :: {send, binary()}               % one binary WebSocket message
                | {close, close_reason()}        % close the connection; nothing follows
                | {open, view(), target()}       % start the view and ask its first update
                | {next, pid()}                  % ask the view for one more update
                | {stop, pid()}                  % end the view's process
                | {event, pid(), binary()}.      % one ui.txt event record, for the renderer

%% A view's pull is `sent` while the view owes an answer, `idle` once it
%% answered, and `deferred` when the browser asked again before the front
%% end reported the pid to forward the request to.
-type pull() :: sent | idle | deferred.
-record(view, {phase :: {opening, pull()} | {open, pid(), sent | idle} | closing,
               ui :: boolean()}).

-record(conn, {phase = hello :: hello | ready | closed,
               welcome :: binary(),
               last = none :: none | view(),
               views = #{} :: #{view() => #view{}}}).
-opaque state() :: #conn{}.

%% How long the line may take to start a view.
-define(LINE_MS, 5000).

-doc """
A connection that has heard nothing yet, for a session of principal
PRINCIPAL on a machine of build BUILD; `{error, Reason}` from the codec when
either is outside `welcome`'s bounds.
""".
-spec new(#{principal := binary(), build := binary()}) -> {ok, state()} | {error, {atom(), atom()}}.
new(#{principal := Principal, build := Build}) ->
    case erx_web_proto:encode(machine, {welcome, Principal, Build}) of
        {ok, Welcome} -> {ok, #conn{welcome = Welcome}};
        {error, _} = Error -> Error
    end.

-doc "The actions INPUT asks of the driver, in order, and the next state.".
-spec step(input(), state()) -> {[action()], state()}.
%% A pid is stopped whatever the phase, so one that arrives after the
%% connection closed does not outlive it.
step({opened, View, Pid}, State) ->
    opened(View, Pid, State);
step(_Input, #conn{phase = closed} = State) ->
    {[], State};
step({in, Bytes}, State) ->
    case erx_web_proto:decode(browser, Bytes) of
        {ok, Message} -> message(Message, State);
        {error, _} -> close(protocol, State)
    end;
step({text, _Bytes}, State) ->
    close(protocol, State);
step({update, View, Body}, State) ->
    update(View, Body, State);
step({ended, View, Reason}, State) ->
    ended(View, Reason, State);
step(tick, State) ->
    close(idle, State).

%% A message from the browser.
message({hello, Hash}, #conn{phase = hello} = State) ->
    case Hash =:= erx_web_proto:hash() of
        true -> {[{send, State#conn.welcome}], State#conn{phase = ready}};
        false -> close(mismatch, State)
    end;
message(_Message, #conn{phase = hello} = State) ->
    close(protocol, State);
message({hello, _Hash}, State) ->
    close(protocol, State);
message({open, View, Target}, State) ->
    open(View, Target, State);
message({next, View}, State) ->
    for_view(View, fun next/3, State);
message({close, View}, State) ->
    for_view(View, fun close_view/3, State);
message({event, View, Record}, State) ->
    for_view(View, fun(Number, Entry, Now) -> event(Number, Entry, Record, Now) end, State).

open(View, _Target, #conn{last = Last} = State) when Last =/= none, View =< Last ->
    close(protocol, State);
open(View, Target, #conn{views = Views} = State) ->
    {integer, _Bits, _Least, Top} = erx_web_proto:type(view),
    Room = map_size(Views) < erx_web_proto:limit(web_views_max),
    if
        View =:= Top ->
            close(limit, State);
        Room ->
            Entry = #view{phase = {opening, sent}, ui = is_ui(Target)},
            {[{open, View, Target}], State#conn{last = View, views = Views#{View => Entry}}};
        true ->
            {[{send, ended_message(View, busy)}], State#conn{last = View}}
    end.

is_ui({ui, _Number}) -> true;
is_ui(_Target) -> false.

%% Applies FUN to an open view, drops a request for a view that is gone and
%% closes on one for a number never opened.
for_view(View, Fun, #conn{last = Last, views = Views} = State) ->
    case Views of
        #{View := #view{phase = closing}} -> {[], State};
        #{View := Entry} -> Fun(View, Entry, State);
        #{} when Last =/= none, View =< Last -> {[], State};
        #{} -> close(protocol, State)
    end.

next(View, #view{phase = {open, Pid, idle}} = Entry, State) ->
    {[{next, Pid}], put_view(View, Entry#view{phase = {open, Pid, sent}}, State)};
next(View, #view{phase = {opening, idle}} = Entry, State) ->
    {[], put_view(View, Entry#view{phase = {opening, deferred}}, State)};
next(_View, #view{}, State) ->
    close(protocol, State).

close_view(View, #view{phase = {open, Pid, _}}, State) ->
    {[{stop, Pid}], drop_view(View, State)};
close_view(View, #view{} = Entry, State) ->
    {[], put_view(View, Entry#view{phase = closing}, State)}.

event(_View, #view{ui = false}, _Record, State) ->
    close(protocol, State);
event(_View, #view{phase = {open, Pid, _}}, Record, State) ->
    {[{event, Pid, Record}], State};
%% A UI whose pid has not arrived has no renderer to take the event; the
%% browser has its tree only if its first update overtook the pid.
event(_View, #view{}, _Record, State) ->
    {[], State}.

%% The front end reports a view's pid. A view the browser closed meanwhile,
%% one the core does not hold and a second pid for one view are stopped.
opened(View, Pid, #conn{phase = ready, views = Views} = State) ->
    case Views of
        #{View := #view{phase = {opening, deferred}} = Entry} ->
            {[{next, Pid}], put_view(View, Entry#view{phase = {open, Pid, sent}}, State)};
        #{View := #view{phase = {opening, Request}} = Entry} ->
            {[], put_view(View, Entry#view{phase = {open, Pid, Request}}, State)};
        #{View := #view{phase = closing}} ->
            {[{stop, Pid}], drop_view(View, State)};
        #{} ->
            {[{stop, Pid}], State}
    end;
opened(_View, Pid, State) ->
    {[{stop, Pid}], State}.

%% A view's answer, sent only when the view owes one.
update(View, Body, #conn{views = Views} = State) ->
    case Views of
        #{View := #view{phase = {opening, sent}} = Entry} ->
            answer(View, Body, Entry#view{phase = {opening, idle}}, State);
        #{View := #view{phase = {open, Pid, sent}} = Entry} ->
            answer(View, Body, Entry#view{phase = {open, Pid, idle}}, State);
        #{} ->
            {[], State}
    end.

answer(View, Body, Answered, State) ->
    case erx_web_proto:encode(machine, {update, View, Body}) of
        {ok, Bytes} -> {[{send, Bytes}], put_view(View, Answered, State)};
        {error, {Bound, _}} when Bound =:= too_long; Bound =:= too_many -> end_view(View, too_large, State);
        {error, _} -> end_view(View, closed, State)
    end.

%% The core ends a view itself: the browser hears `ended`, and a view whose
%% pid has not arrived stays closing, so the pid is stopped when it does.
end_view(View, Reason, #conn{views = Views} = State) ->
    Ended = {send, ended_message(View, Reason)},
    case maps:get(View, Views) of
        #view{phase = {open, Pid, _}} -> {[{stop, Pid}, Ended], drop_view(View, State)};
        #view{} = Entry -> {[Ended], put_view(View, Entry#view{phase = closing}, State)}
    end.

%% A view reports its own end, and is stopped in case it lies. A view the
%% browser closed hears nothing more.
ended(View, Reason, #conn{views = Views} = State) ->
    case Views of
        #{View := #view{phase = closing}} -> {[], drop_view(View, State)};
        #{View := #view{phase = {open, Pid, _}}} ->
            {[{stop, Pid}, {send, ended_message(View, Reason)}], drop_view(View, State)};
        #{View := #view{}} -> {[{send, ended_message(View, Reason)}], drop_view(View, State)};
        #{} -> {[], State}
    end.

%% Closes the connection: every view's process is stopped, the browser
%% hears why unless it went silent, and the core ignores everything after
%% except a late pid, which it stops.
close(Reason, #conn{views = Views} = State) ->
    Stops = [{stop, Pid} || {_View, #view{phase = {open, Pid, _}}} <- lists:sort(maps:to_list(Views))],
    Bye = case Reason of
              idle -> [];
              _ -> [{send, encoded({bye, Reason})}]
          end,
    {Stops ++ Bye ++ [{close, Reason}], State#conn{phase = closed, views = #{}}}.

%% An `ended` for VIEW; a reason that is not an atom or a name, or whose
%% name is over web_name_max bytes, is sent as `closed`, so a view cannot
%% make the core crash or send a message the codec refuses.
ended_message(View, Reason) ->
    case erx_web_proto:encode(machine, {ended, View, reason_name(Reason)}) of
        {ok, Bytes} -> Bytes;
        {error, _} -> encoded({ended, View, <<"closed">>})
    end.

reason_name(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason_name(Reason) when is_binary(Reason) -> Reason;
reason_name(_Reason) -> <<"closed">>.

%% A message the core composes from its own atoms, which the codec always
%% accepts.
encoded(Message) ->
    {ok, Bytes} = erx_web_proto:encode(machine, Message),
    Bytes.

put_view(View, Entry, #conn{views = Views} = State) -> State#conn{views = Views#{View := Entry}}.

drop_view(View, #conn{views = Views} = State) -> State#conn{views = maps:remove(View, Views)}.

%%% The driver's effects.

-doc """
Performs one action of step/2 for a front end, the one function both front
ends perform actions with (W5), and returns the inputs it produced for
step/2, in order. Driver names the front end's own effects, `send` and
`close`, each a fun of the action's argument, and the connection's line,
the session's erx_web_line, or `none` where the connection has none.

* An `open` of a `path` target is a call on the line, which answers the
  view's process, `{opened, View, Pid}`, monitored here so that its end
  reaches the driver as a 'DOWN', or `{ended, View, Reason}` for the line's
  refusal and `{ended, View, unavailable}` when the line did not answer.
  Every other target, and every open without a line, is `{ended, View,
  unsupported}`: the line serves records, and no UI is served yet.
* `next` and `stop` are messages to the view; the view answers a `next`
  with `{web_view, Pid, Body}` or `{web_view_ended, Pid, Reason}`, which the
  driver hands to step/2 as `update` and `ended` of the view it opened as Pid.
* An `event` is dropped, since no UI view opens.
""".
-spec perform(action(), #{send := fun((binary()) -> term()), close := fun((close_reason()) -> term()),
                          line := pid() | none}) -> [input()].
perform({send, Bytes}, #{send := Send}) ->
    _ = Send(Bytes),
    [];
perform({close, Reason}, #{close := Close}) ->
    _ = Close(Reason),
    [];
perform({open, View, {path, _} = Target}, #{line := Line}) when is_pid(Line) ->
    try gen_server:call(Line, {open, Target}, ?LINE_MS) of
        {ok, Pid} when is_pid(Pid) ->
            _ = erlang:monitor(process, Pid),
            [{opened, View, Pid}];
        {error, Reason} when is_atom(Reason) ->
            [{ended, View, Reason}];
        _Other ->
            [{ended, View, failed}]
    catch
        exit:_ -> [{ended, View, unavailable}]
    end;
perform({open, View, _Target}, #{}) ->
    [{ended, View, unsupported}];
perform({next, Pid}, #{}) ->
    Pid ! next,
    [];
perform({stop, Pid}, #{}) ->
    Pid ! stop,
    [];
perform({event, _Pid, _Record}, #{}) ->
    [].
