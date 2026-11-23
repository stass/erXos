%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the loss of input in the line editor and the group (edits 80 and 81 of
%% docs/design-runtime.md, docs/design-live.md "Lost input"). A loss reaches edlin as the
%% input lost, beside the read's damage, which edlin takes and returns; while the read is
%% damaged no line is finished, and the damage ends only when an edit empties the whole
%% buffer, or with the read. A group keeps the damage in each request, damages every
%% unfinished request at a loss, starts a request damaged while any unfinished one is,
%% and holds the loss of a damaged request that ends with an error for the next request.
%% The group cases run a group over a driver the test plays.
%% test/host/edlin_lost_test.rb runs them against the tree's edlin, edlin_key and group.

-module(edlin_lost_tests).
-include_lib("eunit/include/eunit.hrl").

%% A loss damages the read: Enter rings the bell and finishes nothing, and editing goes
%% on, so the bytes after the Enter join the line.
enter_on_a_damaged_line_rings_the_bell_test() ->
    {{more_chars, Cont, Requests}, true} = typed(["cd ", lost, "x\rrm"]),
    ?assertEqual("cd xrm", edlin:current_chars(Cont)),
    ?assert(lists:member(beep, Requests)).

%% A loss rings the bell and drops the escape sequence under way, so the byte after it
%% is a character of the line, not the end of a key.
a_loss_drops_the_escape_sequence_under_way_test() ->
    {{more_chars, _, Requests}, true} = typed(["ls\e[", lost]),
    ?assert(lists:member(beep, Requests)),
    {{more_chars, Cont, _}, true} = typed(["ls\e[", lost, "A"]),
    ?assertEqual("lsA", edlin:current_chars(Cont)).

%% At the end of input a damaged line is dropped and the end handed on.
the_end_of_input_drops_a_damaged_line_test() ->
    ?assertMatch({{done, {[], {[], []}, []}, eof, _}, true}, typed(["ls", lost, eof])).

%% Erasing the whole buffer ends the damage, so the next line finishes.
emptying_the_buffer_ends_the_damage_test() ->
    {{done, Line, [], _}, false} = typed(["ls", lost, "\d\dpwd\r"]),
    ?assertEqual("pwd\n", edlin:current_line(Line)).

%% A key that leaves an empty buffer empty keeps the damage: a loss alone, where a
%% whole command and its newline were lost, survives a habitual Backspace or Ctrl-U.
an_edit_of_an_empty_buffer_keeps_the_damage_test() ->
    ?assertMatch({{more_chars, _, _}, true}, typed([lost, "\d\^Uls\r"])).

%% Emptying one line of a multi-line edit leaves the damage while another line has text.
emptying_one_line_of_several_keeps_the_damage_test() ->
    ?assertMatch({{more_chars, _, _}, true}, typed(["a\e\rb", lost, "\d\r"])).

%% A NUL is a byte, read as stock reads it, a key bound to nothing, and damages nothing.
a_nul_is_an_ordinary_byte_test() ->
    {{done, Line, [], _}, false} = typed(["a" ++ [0] ++ "b\r"]),
    ?assertEqual("ab\n", edlin:current_line(Line)).

%% A character that cannot continue a CSI sequence, a NUL among them, ends it and is
%% read again (edit 73).
a_nul_ends_a_csi_sequence_test() ->
    {{done, Line, [], _}, false} = typed(["ls\e[1" ++ [0] ++ "\r"]),
    ?assertEqual("ls\n", edlin:current_line(Line)).

%% A key cut after two CSI digits by the end of a delivery (an F5 key, ESC [ 1 5 ~) waits
%% for the rest, where stock's parser answers a shape the editor has no clause for.
a_key_cut_after_two_csi_digits_waits_for_the_rest_test() ->
    {{more_chars, Cont, _}, false} = typed(["ls\e[15", "~"]),
    ?assertEqual("ls", edlin:current_chars(Cont)).

%% Through a group: a read answered with a loss runs no line until the user empties the
%% buffer, and then runs only what follows.
a_group_runs_no_damaged_line_test() ->
    with_group(fun(Group, Driver) ->
        Reader = reader(Group),
        feed(Group, Driver, ["cd ", lost, "/tmp\r"]),
        ?assertEqual(none, answer(Reader)),
        feed(Group, Driver, ["\^U", "\^U", "pwd\r"]),
        ?assertEqual("pwd\n", answer(Reader)),
        ?assert(rang())
    end).

%% Through a group: the end of input on a damaged read ends it.
a_group_ends_a_damaged_read_at_the_end_of_input_test() ->
    with_group(fun(Group, Driver) ->
        Reader = reader(Group),
        feed(Group, Driver, ["ls", lost, eof]),
        ?assertEqual(eof, answer(Reader))
    end).

%% Through a group: a loss damages the request set aside as well as the current one,
%% since the group's ask may be answered to either; mending the nested read leaves the
%% outer one damaged.
a_group_damages_every_unfinished_request_test() ->
    with_group(fun(Group, Driver) ->
        Outer = reader(Group),
        feed(Group, Driver, ["cd "]),
        Inner = reader(Group),
        feed(Group, Driver, [lost, "x", "\d", "y\r"]),
        ?assertEqual("y\n", answer(Inner)),
        feed(Group, Driver, ["\r"]),
        ?assertEqual(none, answer(Outer))
    end).

%% Through a group: a request that starts while an unfinished one is damaged starts
%% damaged.
a_group_starts_a_request_damaged_test() ->
    with_group(fun(Group, Driver) ->
        Outer = reader(Group),
        feed(Group, Driver, ["cd ", lost]),
        Inner = reader(Group),
        feed(Group, Driver, ["ls\r"]),
        ?assertEqual(none, answer(Inner)),
        ?assertEqual(none, answer(Outer))
    end).

%% Through a group: a damaged request that ends with an error leaves its loss for the
%% next request, which starts damaged.
a_group_holds_the_loss_of_a_failed_request_test() ->
    with_group(fun(Group, Driver) ->
        First = reader(Group),
        feed(Group, Driver, ["ls", lost]),
        Group ! {Driver, {error, eio}},
        ?assertEqual({error, eio}, answer(First)),
        Next = reader(Group),
        feed(Group, Driver, ["\r"]),
        ?assertEqual(none, answer(Next))
    end).

%% Through a group: Ctrl-C ends a damaged request and its damage, so the next request
%% runs its line.
a_group_ends_the_damage_with_an_interrupt_test() ->
    with_group(fun(Group, Driver) ->
        First = reader(Group),
        feed(Group, Driver, ["ls", lost]),
        Group ! {'EXIT', Driver, interrupt},
        ?assertEqual({error, interrupted}, answer(First)),
        Next = reader(Group),
        feed(Group, Driver, ["pwd\r"]),
        ?assertEqual("pwd\n", answer(Next))
    end).

%% Through a group: a history move keeps the damage, and a damaged line left by Up is
%% not kept to come back to, so emptying the recalled line and moving Down cannot bring
%% the damaged line back undamaged.
a_group_keeps_no_damaged_line_to_come_back_to_test() ->
    with_group(fun(Group, Driver) ->
        First = reader(Group),
        feed(Group, Driver, ["ls\r"]),
        ?assertEqual("ls\n", answer(First)),
        Next = reader(Group),
        feed(Group, Driver, ["rm ", lost, "\e[A", "\^U", "\e[B", "\r"]),
        ?assertEqual("\n", answer(Next))
    end).

%% Through a group in dumb mode: a damaged read returns no line, and the end of input
%% ends it.
a_dumb_group_returns_no_damaged_line_test() ->
    with_group([{dumb, true}], fun(Group, Driver) ->
        Reader = reader(Group),
        feed(Group, Driver, ["ls", lost, "\n"]),
        ?assertEqual(none, answer(Reader)),
        feed(Group, Driver, [eof]),
        ?assertEqual(eof, answer(Reader))
    end).

%% Through a group: a password read nested in an edited one takes a loss; it returns no
%% line and ends at Ctrl-C, and the edited read resumes damaged.
a_group_damages_a_read_a_password_read_set_aside_test() ->
    with_group(fun(Group, Driver) ->
        Outer = reader(Group),
        feed(Group, Driver, ["ls"]),
        Test = self(),
        Password = spawn_link(fun() -> Test ! {line, self(), io:get_password(Group)} end),
        feed(Group, Driver, [lost, "secret\n"]),
        ?assertEqual(none, answer(Password)),
        Group ! {'EXIT', Driver, interrupt},
        ?assertEqual({error, interrupted}, answer(Password)),
        feed(Group, Driver, ["\r"]),
        ?assertEqual(none, answer(Outer))
    end).

%% What the editor makes of Inputs, in turn, at a fresh undamaged prompt: the last
%% result and the damage.
typed(Inputs) ->
    edlin:init(),
    {more_chars, Start, _} = edlin:start("> "),
    lists:foldl(fun(Input, {{_, Cont, _}, Damage}) -> edlin:edit_line(Input, Cont, Damage) end,
                {{more_chars, Start, []}, false}, Inputs).

with_group(Fun) ->
    with_group([{dumb, false}], Fun).

%% Runs Fun with a group over a driver the test plays.
with_group(Options, Fun) ->
    Test = self(),
    Driver = spawn_link(fun() -> driver(Test) end),
    Group = group:start(Driver, noshell, Options),
    try
        Fun(Group, Driver)
    after
        [begin unlink(Pid), exit(Pid, kill) end || Pid <- [Group, Driver]]
    end.

%% A process that reads a line from Group and sends the test what it read.
reader(Group) ->
    Test = self(),
    spawn_link(fun() -> Test ! {line, self(), io:get_line(Group, "> ")} end).

%% Answers the group's asks in turn, one per chunk: a chunk lost as a loss, eof as the end
%% of input, and any other as its bytes.
feed(Group, Driver, Chunks) ->
    lists:foreach(fun(Chunk) ->
                          Ref = receive {asked, R} -> R after 5000 -> error(no_ask) end,
                          Group ! case Chunk of
                                      eof -> {Driver, eof};
                                      _ -> {Driver, {read, Ref, Chunk}}
                                  end
                  end, Chunks).

%% The line Reader read, or none if none comes within half a second.
answer(Reader) ->
    receive {line, Reader, Line} -> Line after 500 -> none end.

%% Whether the driver was asked to ring the bell.
rang() ->
    receive beep -> true after 0 -> false end.

%% The group's driver: each ask for input and each bell, to the test.
driver(Test) ->
    receive
        {_Group, read, Ref} -> Test ! {asked, Ref};
        {_Group, beep} -> Test ! beep;
        {_Group, {requests, Requests}} -> [Test ! beep || beep <- Requests];
        _Output -> ok
    end,
    driver(Test).
