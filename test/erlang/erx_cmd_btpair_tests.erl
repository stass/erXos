%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_btpair_tests).
-moduledoc """
EUnit cases of the command shell's `btpair` (erx_cmd_btpair,
docs/design-bluetooth.md, "The pairing window"): the mode each command
line asks for, the shell's usage line and its no_facet for a session
without the `bluetooth` grant, a host with no Bluetooth tree, and a
window driven over a stub pair file (erx_bt_pair_stub), one case for each
status: a bonded outcome then the end of the file succeeds; a failed
pairing, a timeout, the end of the file with no outcome, an invalid line,
an overlong line, a file that ends inside a line and a refused write
fail; an interrupt and a failed print still close the file. Every case
checks the mode written, each line printed and that the file was closed.
""".

-include_lib("eunit/include/eunit.hrl").

-define(BOND, <<"0123456789abcdef0123456789abcdef C0:01:02:AB:CD:EF random unauthenticated">>).
-define(FAILURE, 1).

%% ---------------------------------------------------------------------------
%% Through the shell
%% ---------------------------------------------------------------------------

run_line(Source, Facets) ->
    {Table, []} = erx_shell_namespace:build(
                    [{erx_cmd_btpair, erx_cmd_btpair:module_info(attributes),
                      erx_cmd_btpair:module_info(exports)}]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> Facets end}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(Source, Shell),
    {erx_shell_eval:status(Done), shown(out), shown(err)}.

sink(Stream) ->
    Me = self(),
    {tty, fun(Bytes) -> Me ! {Stream, iolist_to_binary(Bytes)}, ok end}.

shown(Stream) -> shown(Stream, []).

shown(Stream, Acc) ->
    receive {Stream, Bytes} -> shown(Stream, [Acc, Bytes])
    after 0 -> iolist_to_binary(Acc)
    end.

parse_test_() ->
    [?_assertEqual({ok, display}, erx_cmd_btpair:parse([<<"display">>])),
     ?_assertEqual({ok, nodisplay}, erx_cmd_btpair:parse([<<"nodisplay">>])),
     [?_assertEqual({error, usage}, erx_cmd_btpair:parse(Args))
      || Args <- [[], [<<"Display">>], [<<"display">>, <<"display">>], [<<"-d">>], [<<"display\n">>]]]].

%% A session without the grant: the shell refuses before the command starts.
no_facet_test() ->
    ?assertEqual({<<"no_facet">>, <<>>, <<"btpair: no_facet\n">>}, run_line(<<"btpair display">>, #{})).

usage_test_() ->
    [?_assertEqual({<<"usage">>, <<>>, <<"usage: btpair display | nodisplay\n">>},
                   run_line(Line, #{bluetooth => grant}))
     || Line <- [<<"btpair">>, <<"btpair pair">>, <<"btpair display now">>]].

%% The host has no tree named bluetooth: the open answers not_serving.
no_tree_test() ->
    ?assertEqual({<<"1">>, <<>>, <<"btpair: bluetooth not running?\n">>},
                 run_line(<<"btpair nodisplay">>, #{bluetooth => grant})).

%% ---------------------------------------------------------------------------
%% A window over a stub pair file
%% ---------------------------------------------------------------------------

%% The status, standard output and standard error of a window in Mode over a stub that
%% serves Data as Plan says and answers each write with Write, and the stub.
window(Mode, Data, Plan, Write) ->
    Stub = erx_bt_pair_stub:start(Data, Plan, Write),
    Ctx = #{name => <<"btpair">>, cwd => <<"/">>, env => #{}, stdin => null,
            stdout => sink(out), stderr => sink(err), facets => #{bluetooth => grant}},
    Status = erx_cmd_btpair:window(Stub, Mode, Ctx),
    {status(Status), shown(out), shown(err), Stub}.

window(Mode, Data) -> window(Mode, Data, all, ok).

status(ok) -> 0;
status({error, {reported, <<"1">>}}) -> ?FAILURE.

a_bonded_outcome_then_the_end_succeeds_test() ->
    Lines = <<"wait 12\nwaiting\npasskey 012345 C0:01:02:AB:CD:EF\nbonded ", ?BOND/binary, "\n">>,
    {Status, Out, Err, Stub} = window(display, Lines, 5, ok),
    ?assertEqual({0, Lines, <<>>}, {Status, Out, Err}),
    ?assertEqual(<<"display\n">>, erx_bt_pair_stub:written(Stub)),
    ?assert(erx_bt_pair_stub:closed(Stub)).

a_failed_pairing_fails_test() ->
    Lines = <<"waiting\nfailed C0:01:02:AB:CD:EF bonds_full\n">>,
    {Status, Out, Err, Stub} = window(nodisplay, Lines),
    ?assertEqual({?FAILURE, Lines, <<>>}, {Status, Out, Err}),
    ?assertEqual(<<"nodisplay\n">>, erx_bt_pair_stub:written(Stub)),
    ?assert(erx_bt_pair_stub:closed(Stub)).

a_timeout_fails_test() ->
    Lines = <<"waiting\nclosed timeout\n">>,
    {Status, Out, _Err, Stub} = window(nodisplay, Lines),
    ?assertEqual({?FAILURE, Lines}, {Status, Out}),
    ?assert(erx_bt_pair_stub:closed(Stub)).

the_end_without_an_outcome_fails_test() ->
    {Status, Out, _Err, Stub} = window(display, <<"wait 3\nwaiting\n">>),
    ?assertEqual({?FAILURE, <<"wait 3\nwaiting\n">>}, {Status, Out}),
    ?assert(erx_bt_pair_stub:closed(Stub)).

%% A failure after the bond fails the window: once failed, it stays failed.
a_failure_after_the_bond_fails_test() ->
    Lines = <<"bonded ", ?BOND/binary, "\nfailed C0:01:02:AB:CD:EF timeout\n">>,
    {Status, Out, _Err, _Stub} = window(display, Lines),
    ?assertEqual({?FAILURE, Lines}, {Status, Out}).

%% A bounded line that does not parse prints [invalid] in its place, never its bytes,
%% and the reading goes on to the end of the file; the window still fails.
an_invalid_line_prints_invalid_and_fails_test() ->
    Evil = <<"passkey 012345 \e]8;;http://x\e\\C0:01:02:AB:CD:EF\e[2J">>,
    Lines = <<"waiting\n", Evil/binary, "\nbonded ", ?BOND/binary, "\n">>,
    {Status, Out, _Err, Stub} = window(display, Lines),
    ?assertEqual({?FAILURE, <<"waiting\n[invalid]\nbonded ", ?BOND/binary, "\n">>}, {Status, Out}),
    ?assertEqual(nomatch, binary:match(Out, <<"\e">>)),
    ?assertEqual(byte_size(Lines), erx_bt_pair_stub:served(Stub)),
    ?assert(erx_bt_pair_stub:closed(Stub)).

%% A stream with no newline within bt_pair_line_max + 1 octets prints [invalid], ends
%% with a failure and closes the file at once, having read no more than the bound.
an_overlong_line_prints_invalid_and_closes_at_once_test() ->
    Stream = <<"waiting\n", (binary:copy(<<"A">>, 4096))/binary, "\nbonded ", ?BOND/binary, "\n">>,
    {Status, Out, _Err, Stub} = window(display, Stream),
    ?assertEqual({?FAILURE, <<"waiting\n[invalid]\n">>}, {Status, Out}),
    ?assert(erx_bt_pair_stub:closed(Stub)),
    ?assertEqual(byte_size(<<"waiting\n">>) + 129, erx_bt_pair_stub:served(Stub)).

a_file_that_ends_inside_a_line_fails_test() ->
    {Status, Out, Err, Stub} = window(display, <<"waiting\nbonded 0123">>),
    ?assertEqual({?FAILURE, <<"waiting\n">>}, {Status, Out}),
    ?assertMatch(<<"btpair: ", _/binary>>, Err),
    ?assert(erx_bt_pair_stub:closed(Stub)).

a_read_error_fails_test() ->
    {Status, Out, Err, Stub} = window(display, {reply, {error, eio}}, all, ok),
    ?assertEqual({?FAILURE, <<>>}, {Status, Out}),
    ?assertMatch(<<"btpair: ", _/binary>>, Err),
    ?assertEqual([129], erx_bt_pair_stub:asked(Stub)),
    ?assert(erx_bt_pair_stub:closed(Stub)).

%% A refused write is reported once and never retried, and nothing is read.
a_refused_write_fails_and_is_not_retried_test() ->
    {Status, Out, Err, Stub} = window(display, <<"waiting\n">>, all, {error, eio}),
    ?assertEqual({?FAILURE, <<>>}, {Status, Out}),
    ?assertMatch(<<"btpair: ", _/binary>>, Err),
    ?assertEqual(<<"display\n">>, erx_bt_pair_stub:written(Stub)),
    ?assertEqual([], erx_bt_pair_stub:asked(Stub)),
    ?assert(erx_bt_pair_stub:closed(Stub)).

%% An interrupt ends the command's process mid-read, so no `after` runs: the file is
%% closed by its owner's end, which the stub sees as a clunk.
an_interrupt_closes_the_file_test() ->
    Stub = erx_bt_pair_stub:start(hold, all, ok),
    Ctx = #{name => <<"btpair">>, stdout => sink(out), stderr => sink(err)},
    Command = spawn(fun() -> erx_cmd_btpair:window(Stub, display, Ctx) end),
    ?assert(soon(fun() -> erx_bt_pair_stub:asked(Stub) =/= [] end)),
    exit(Command, kill),
    ?assert(soon(fun() -> erx_bt_pair_stub:closed(Stub) end)),
    ?assertEqual(<<"display\n">>, erx_bt_pair_stub:written(Stub)).

%% A write to standard output that ends the command still closes the file.
a_failed_print_closes_the_file_test() ->
    Stub = erx_bt_pair_stub:start(<<"waiting\n">>, all, ok),
    Ctx = #{name => <<"btpair">>, stdout => {tty, fun(_) -> {error, epipe} end}, stderr => sink(err)},
    ?assertThrow({erx_cmd_stop, epipe}, erx_cmd_btpair:window(Stub, display, Ctx)),
    ?assert(erx_bt_pair_stub:closed(Stub)).

%% Whether Holds() answers true within a second.
soon(Holds) -> soon(Holds, 100).

soon(_Holds, 0) -> false;
soon(Holds, Tries) ->
    Holds() orelse begin timer:sleep(10), soon(Holds, Tries - 1) end.
