%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart_core).
-moduledoc """
The relay of one client of bleuart (docs/design-bluetooth.md, "The console"),
pure: the master's side of one tty of root's session, opened for one connection
to Nordic's UART service, between that connection's byte stream and the tty's
messages (docs/design-live.md, "Between domains"). erx_bleuart_channel carries its
actions out. Each step takes one event and returns the actions it decides, in
order, and the next state.

* **Input.** Each `{serial, Bytes}`, a write of `rx`, is `{tty_input, Bytes}` to
  the tty, in order and in parts of at most 4 KiB, whether or not the client has
  subscribed. A `serial_lost`, a gap in the stream, ends the relay, as does a write
  before the tty names itself, which has no tty to go to: so the bytes after a gap
  never complete a line the bytes before it began.
* **Output.** Every message from the tty is checked by the console's own master
  core, erx_tty_master, whose actions this relay carries: an output is written to
  the client (`{write, N, Bytes}`, answered `{written, N}` once the send returns)
  only while the client is subscribed to `tx`, a subscription made before the tty
  names itself included, and held unanswered before, so the
  shell's first prompt waits for the client. The client reports no size, so the
  master is connected with none and the tty keeps its own.
* **The tty.** Only messages of root's session's domain, the domain the line was
  minted of, are the tty's; any other domain's is ignored. The first
  `{tty_open, Tty}` names the tty if Tty is a process of that domain; the same
  again is nothing; a process of another domain, a second tty, or a message the
  master refuses ends the relay. Messages
  before the tty is named are dropped: the tty sends its `tty_open` again with
  each resend.
* **The end.** The relay ends at `disconnected`, at a loss of input and at a
  refusal, each with `tty_hangup` to a tty it knows, which ends the shell and its
  jobs, and then `stop`. The shell's own end ends it too: the line reports how the
  shell ended, `{exited, Status}` or `{signaled, Signal}`, once the shell has ended
  and its last output was taken, so the report is `stop` alone. Every end but the
  disconnect first tells the client, with `{notice, Line}`, one constant line, since
  its link stays up. An ended relay takes nothing more.

A write before the tty names itself is rare: the tty's relay sends its `tty_open` in
its own start, before the line answers the `open_tty` that erx_bleuart waits on.
""".

-export([new/2, step/2, status/1]).

%% The most bytes one tty_input carries.
-define(MAX_INPUT, 4096).
%% The client's notices, the relay's only bytes of its own.
-define(INPUT_LOST, <<"\r\nbleuart: input was lost; the shell has ended\r\n">>).
-define(SHELL_ENDED, <<"\r\nbleuart: the shell has ended\r\n">>).
-define(REFUSED, <<"\r\nbleuart: root's tty failed a check; the shell has ended\r\n">>).
-export_type([core/0, event/0, action/0]).

-type event() :: {serial, binary()}                % a write of rx
               | serial_lost                       % writes dropped since the last one
               | {subscribed, none | notify | indicate}   % the client's subscription to tx
               | disconnected
               | {tty, Domain :: non_neg_integer(), Message :: term()}   % from another domain
               | {written, non_neg_integer()}.     % a {write, N, _} has been sent

-type action() :: {to_tty, pid(), term()}          % a message to the tty
                | {write, non_neg_integer(), binary()}   % send to the client, then {written, N}
                | {lost_output, non_neg_integer()} % log that output N's bytes were lost
                | {notice, binary()}               % send the client this constant line
                | stop.                            % the relay has ended

-record(core, {
          %% Root's session's domain, of which the tty must be a process.
          domain :: non_neg_integer(),
          %% Which domain a pid is of (erx:owner/1).
          owner :: fun((pid()) -> non_neg_integer()),
          tty = none :: none | pid(),
          master = erx_tty_master:new() :: erx_tty_master:master(),
          ended = false :: boolean()}).

-opaque core() :: #core{}.

-doc "A relay for a tty of root's session, Domain, that has not named itself yet.".
-spec new(non_neg_integer(), fun((pid()) -> non_neg_integer())) -> core().
new(Domain, Owner) when is_integer(Domain), is_function(Owner, 1) ->
    #core{domain = Domain, owner = Owner}.

-doc "Whether the relay runs or has ended.".
-spec status(core()) -> open | ended.
status(#core{ended = true}) -> ended;
status(#core{}) -> open.

-doc "One event, and the actions it decides.".
-spec step(event(), core()) -> {[action()], core()}.
step(_Event, C = #core{ended = true}) ->
    {[], C};
step({serial, Bytes}, C = #core{tty = Tty}) when is_pid(Tty) ->
    {[{to_tty, Tty, {tty_input, Part}} || Part <- parts(Bytes)], C};
step({serial, _Bytes}, C = #core{tty = none}) ->
    hang_up(?INPUT_LOST, C);
step(serial_lost, C) ->
    hang_up(?INPUT_LOST, C);
step({subscribed, none}, C = #core{master = M}) ->
    {[], C#core{master = erx_tty_master:disconnect(M)}};
step({subscribed, _Kind}, C = #core{master = M}) ->
    master(erx_tty_master:connect(none, M), C);
step(disconnected, C) ->
    hang_up(none, C);
step({tty, Domain, Message}, C = #core{domain = Domain}) ->
    from_tty(Message, C);
step({tty, _Domain, _Message}, C) ->
    {[], C};
step({written, N}, C = #core{master = M}) ->
    master(erx_tty_master:written(N, M), C).

%% The line reports how the shell ended once it has, so the tty needs no hangup.
from_tty({exited, _Status}, C) ->
    {[{notice, ?SHELL_ENDED}, stop], C#core{ended = true}};
from_tty({signaled, _Signal}, C) ->
    {[{notice, ?SHELL_ENDED}, stop], C#core{ended = true}};
from_tty({tty_open, Tty}, C = #core{tty = none, domain = Domain, owner = Owner}) when is_pid(Tty) ->
    case Owner(Tty) of
        Domain -> {[], C#core{tty = Tty}};
        _Other -> hang_up(?REFUSED, C)
    end;
from_tty({tty_open, Tty}, C = #core{tty = Tty}) ->
    {[], C};
from_tty({tty_open, _Tty}, C) ->
    hang_up(?REFUSED, C);
from_tty(_Message, C = #core{tty = none}) ->
    {[], C};
from_tty(Message, C = #core{master = M}) ->
    master(erx_tty_master:output(Message, M), C).

%% The master's actions, each addressed to the tty or the client; a refusal ends the
%% relay.
master({Actions, M}, C = #core{tty = Tty}) ->
    case lists:member(detach, Actions) of
        true -> hang_up(?REFUSED, C#core{master = M});
        false -> {[carried(Action, Tty) || Action <- Actions], C#core{master = M}}
    end.

carried({write, N, Bytes}, _Tty) -> {write, N, Bytes};
carried({send, Message}, Tty) -> {to_tty, Tty, Message};
carried({lost, N}, _Tty) -> {lost_output, N}.

%% Bytes in parts of at most 4 KiB, the most a tty_input carries (erx_tty_link drops a
%% longer one). A write of rx is at most att_value_max bytes, so it is one part today.
parts(<<Part:?MAX_INPUT/binary, Rest/binary>>) when Rest =/= <<>> -> [Part | parts(Rest)];
parts(<<>>) -> [];
parts(Part) -> [Part].

%% The end of the relay: tty_hangup to a tty it knows, the client's notice unless it
%% disconnected, then stop.
hang_up(Notice, C = #core{tty = Tty}) ->
    {[{to_tty, Tty, tty_hangup} || is_pid(Tty)] ++ [{notice, Notice} || Notice =/= none] ++ [stop],
     C#core{ended = true}}.
