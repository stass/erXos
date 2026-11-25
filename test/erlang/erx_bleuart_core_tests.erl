%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart_core_tests).
-moduledoc """
The relay of one client of bleuart (docs/design-bluetooth.md, "The console"),
erx_bleuart_core: a phone's bytes reach root's tty as tty input in order, a
serial_lost ends the relay with a hangup, output is held until the client
subscribes to tx and taken after, a disconnect hangs the tty up, the shell's end
ends the relay, and messages of any other domain, or a tty that names a process
of another domain, never reach the master.
""".

-include_lib("eunit/include/eunit.hrl").

%% Root's session's domain, the one the line was minted of, and another.
-define(ROOT, 7).
-define(OTHER, 9).
%% The client's notices at an end it did not cause.
-define(LOST, {notice, <<"\r\nbleuart: input was lost; the shell has ended\r\n">>}).
-define(ENDED, {notice, <<"\r\nbleuart: the shell has ended\r\n">>}).
-define(REFUSED, {notice, <<"\r\nbleuart: root's tty failed a check; the shell has ended\r\n">>}).

%% A pid stands for root's tty; owner/1 says which domain a pid is of.
tty() -> list_to_pid("<0.4242.0>").
stranger() -> list_to_pid("<0.4343.0>").

owner(Pid) ->
    case Pid =:= tty() of
        true -> ?ROOT;
        false -> ?OTHER
    end.

new() -> erx_bleuart_core:new(?ROOT, fun owner/1).

%% Core C after each event of Events, and every action they gave, in order.
run(Events, C0) ->
    lists:foldl(fun(Event, {Actions, C}) ->
                        {More, Next} = erx_bleuart_core:step(Event, C),
                        {Actions ++ More, Next}
                end, {[], C0}, Events).

opened() ->
    {[], C} = run([{tty, ?ROOT, {tty_open, tty()}}], new()),
    C.

%% The bytes root's tty takes of the relay's messages, in order, as its own side of
%% them, erx_tty_link, reads them: the relay's input is input only if the tty takes it.
input(Actions) ->
    {Taken, _Link} = lists:foldl(fun({to_tty, _, Message}, {Bytes, L0}) ->
                                         {More, L} = erx_tty_link:master(Message, L0),
                                         {Bytes ++ [B || {input, B} <- More], L};
                                    (_Action, Acc) ->
                                         Acc
                                 end, {[], erx_tty_link:new(present)}, Actions),
    Taken.

input_in_order_test() ->
    {Actions, _} = run([{serial, <<"cd /t">>}, {serial, <<"mp\r">>}], opened()),
    ?assertEqual([<<"cd /t">>, <<"mp\r">>], input(Actions)).

%% Input reaches the tty whether or not the client has subscribed to tx.
input_before_the_subscription_test() ->
    {Actions, _} = run([{serial, <<"a">>}, {subscribed, notify}, {serial, <<"b">>},
                        {subscribed, none}, {serial, <<"c">>}], opened()),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], input(Actions)).

%% A gap ends the relay, so the bytes after it never complete the line before it.
a_loss_hangs_the_tty_up_test() ->
    {Actions, C} = run([{serial, <<"cd /t">>}, serial_lost, {serial, <<"mp\r">>}], opened()),
    ?assertEqual([<<"cd /t">>], input(Actions)),
    ?assertEqual({[{to_tty, tty(), tty_hangup}, ?LOST, stop], ended},
                 status({lists:nthtail(1, Actions), C})).

%% Bytes before the tty names itself have nowhere to go: they are a loss.
bytes_before_the_tty_end_the_relay_test() ->
    ?assertEqual({[?LOST, stop], ended}, status(run([{serial, <<"rm -rf /">>}], new()))),
    ?assertEqual({[?LOST, stop], ended}, status(run([serial_lost], new()))).

%% The line reports the shell's end once the shell has ended: no hangup, a notice.
the_shells_end_ends_the_relay_test() ->
    ?assertEqual({[?ENDED, stop], ended}, status(run([{tty, ?ROOT, {exited, 0}}], opened()))),
    ?assertEqual({[?ENDED, stop], ended}, status(run([{tty, ?ROOT, {signaled, sigint}}], opened()))),
    ?assertEqual({[], open}, status(run([{tty, ?OTHER, {exited, 0}}], opened()))).

output_is_held_until_subscribed_test() ->
    {Held, C1} = run([{tty, ?ROOT, {tty_output, 0, <<"% ">>}}], opened()),
    ?assertEqual([], Held),
    {Written, C2} = run([{subscribed, notify}], C1),
    ?assertEqual([{write, 0, <<"% ">>}], Written),
    {Taken, _} = run([{written, 0}], C2),
    ?assertEqual([{to_tty, tty(), {tty_taken, 0}}], Taken).

%% The client never reports a size, so the master sends the tty none.
no_size_reaches_the_tty_test() ->
    {Actions, _} = run([{subscribed, notify}, {tty, ?ROOT, {tty_output, 0, <<"a">>}}, {written, 0},
                        {tty, ?ROOT, {tty_output, 0, <<>>}}], opened()),
    ?assertEqual([], [Size || {to_tty, _, {tty_size, _, _} = Size} <- Actions]).

unsubscribing_holds_output_again_test() ->
    {Actions, _} = run([{subscribed, notify}, {subscribed, none}, {tty, ?ROOT, {tty_output, 0, <<"a">>}}], opened()),
    ?assertEqual([], Actions).

disconnect_hangs_the_tty_up_test() ->
    ?assertEqual({[{to_tty, tty(), tty_hangup}, stop], ended},
                 status(run([disconnected], opened()))),
    ?assertEqual({[stop], ended}, status(run([disconnected], new()))).

%% A message of another domain is ignored; a tty_open naming a process of another
%% domain, a second tty, or an output the master refuses ends the relay.
other_domains_and_bad_ttys_test() ->
    ?assertEqual({[], open}, status(run([{tty, ?OTHER, {tty_open, tty()}}], new()))),
    ?assertEqual({[], open}, status(run([{tty, ?OTHER, {tty_output, 0, <<"x">>}}], opened()))),
    ?assertEqual({[?REFUSED, stop], ended}, status(run([{tty, ?ROOT, {tty_open, stranger()}}], new()))),
    ?assertEqual({[{to_tty, tty(), tty_hangup}, ?REFUSED, stop], ended},
                 status(run([{tty, ?ROOT, {tty_open, stranger()}}], opened()))),
    ?assertEqual({[{to_tty, tty(), tty_hangup}, ?REFUSED, stop], ended},
                 status(run([{tty, ?ROOT, {tty_output, 5, <<"x">>}}], opened()))),
    ?assertEqual({[], open}, status(run([{tty, ?ROOT, {tty_open, tty()}}], opened()))).

%% Messages before the tty names itself carry no tty to answer, and are dropped: the
%% tty sends its tty_open again with each resend. A subscription made before it is
%% kept, so the tty's first output is written.
output_before_the_tty_is_dropped_test() ->
    {Before, C} = run([{subscribed, notify}, {tty, ?ROOT, {tty_output, 0, <<"x">>}}], new()),
    ?assertEqual({[], open}, status({Before, C})),
    {After, _} = run([{tty, ?ROOT, {tty_open, tty()}}, {tty, ?ROOT, {tty_output, 0, <<"% ">>}}], C),
    ?assertEqual([{write, 0, <<"% ">>}], After).

%% Input longer than a tty_input carries reaches the tty whole, in parts of 4 KiB.
long_input_is_split_test() ->
    {Actions, _} = run([{serial, binary:copy(<<"a">>, 4097)}], opened()),
    ?assertEqual([4096, 1], [byte_size(Bytes) || Bytes <- input(Actions)]).

%% An ended relay takes nothing more.
an_ended_relay_is_silent_test() ->
    {_, C} = run([disconnected], opened()),
    ?assertEqual({[], ended}, status(run([{serial, <<"x">>}, serial_lost, {tty, ?ROOT, {tty_output, 0, <<"x">>}}], C))).

status({Actions, C}) -> {Actions, erx_bleuart_core:status(C)}.
