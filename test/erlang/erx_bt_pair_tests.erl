%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The control tree's lines, erx_bt_pair (docs/design-bluetooth.md, "The client", "The
%% pairing window"): one bond record and the window's lines both ways, and the bounded
%% reading of another domain's file through next/1 and bonds/1, over a stub file
%% (erx_bt_pair_stub) that splits what it serves into reads as a case asks and keeps
%% every count asked.

-module(erx_bt_pair_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(MAX, ?ERX_BT_PAIR_LINE_MAX).
-define(PHONE, <<16#C0, 1, 2, 16#AB, 16#CD, 16#EF>>).
-define(ID, <<"0123456789abcdef0123456789abcdef">>).

bonds_of_every_kind() ->
    [#{id => ?ID, address => ?PHONE, type => Type, level => Level}
     || Type <- [public, random], Level <- [authenticated, unauthenticated]].

every_line() ->
    [{wait, 1}, {wait, 64}, waiting, {passkey, <<"012345">>, ?PHONE}, {closed, timeout}]
    ++ [{bonded, Bond} || Bond <- bonds_of_every_kind()]
    ++ [{failed, ?PHONE, Reason} || Reason <- reasons()].

reasons() ->
    [secure_connections_required, key_size, method, confirm, dhkey, bonding, invalid, unexpected,
     peer, timeout, already_bonded, bonds_full, unavailable, disconnected].

%% One bond record ---------------------------------------------------------------

a_bond_record_round_trips_and_is_the_rest_of_a_bonded_line_test() ->
    lists:foreach(
      fun(Bond) ->
              Text = erx_bt_pair:format_bond(Bond),
              ?assertEqual(Bond, erx_bt_pair:parse_bond(Text)),
              Bonded = erx_bt_pair:format({bonded, Bond}),
              ?assertEqual(<<"bonded ", Text/binary>>, Bonded),
              ?assertEqual({bonded, erx_bt_pair:parse_bond(Text)}, erx_bt_pair:parse(Bonded))
      end, bonds_of_every_kind()).

a_bond_record_reads_as_the_design_writes_it_test() ->
    ?assertEqual(<<"0123456789abcdef0123456789abcdef C0:01:02:AB:CD:EF random unauthenticated">>,
                 erx_bt_pair:format_bond(#{id => ?ID, address => ?PHONE, type => random,
                                           level => unauthenticated})).

%% The window's lines ------------------------------------------------------------

parse_reads_back_every_line_format_makes_test() ->
    [?assertEqual(Line, erx_bt_pair:parse(erx_bt_pair:format(Line))) || Line <- every_line()].

the_lines_read_as_the_design_writes_them_test() ->
    ?assertEqual(<<"wait 12">>, erx_bt_pair:format({wait, 12})),
    ?assertError(function_clause, erx_bt_pair:format({wait, ?ERX_BT_PAIR_WAIT_MAX_S + 1})),
    ?assertEqual(<<"waiting">>, erx_bt_pair:format(waiting)),
    ?assertEqual(<<"passkey 012345 C0:01:02:AB:CD:EF">>, erx_bt_pair:format({passkey, <<"012345">>, ?PHONE})),
    ?assertEqual(<<"failed C0:01:02:AB:CD:EF bonds_full">>, erx_bt_pair:format({failed, ?PHONE, bonds_full})),
    ?assertEqual(<<"closed timeout">>, erx_bt_pair:format({closed, timeout})).

the_longest_line_is_80_octets_within_the_bound_test() ->
    Longest = lists:max([byte_size(erx_bt_pair:format(Line)) || Line <- every_line()]),
    ?assertEqual(80, Longest),
    ?assert(Longest =< ?MAX).

parse_answers_invalid_for_anything_else_test() ->
    Bond = erx_bt_pair:format_bond(hd(bonds_of_every_kind())),
    Invalid = [<<>>, <<"wait">>, <<"wait 0">>, <<"wait 012">>, <<"wait 65">>, <<"wait 1000">>, <<"wait -1">>, <<"wait 1 ">>, <<" waiting">>,
               <<"waiting\n">>, <<"waiting\r">>, <<"Waiting">>, <<"wait\e[2J 1">>,
               <<"passkey 01234 C0:01:02:AB:CD:EF">>, <<"passkey 0123456 C0:01:02:AB:CD:EF">>,
               <<"passkey 01234a C0:01:02:AB:CD:EF">>, <<"passkey 012345 c0:01:02:ab:cd:ef">>,
               <<"passkey 012345 C0:01:02:AB:CD">>, <<"passkey 012345 C0-01-02-AB-CD-EF">>,
               <<"passkey  012345 C0:01:02:AB:CD:EF">>, <<"failed C0:01:02:AB:CD:EF nope">>,
               <<"failed C0:01:02:AB:CD:EF">>, <<"failed C0:01:02:AB:CD:EF Peer">>,
               <<"closed">>, <<"closed now">>, <<"bonded">>, <<"bonded ", Bond/binary, " x">>,
               <<"bonded  ", Bond/binary>>, <<"bonded\t", Bond/binary>>, <<"bonded ", Bond/binary, 0>>],
    [?assertEqual({Line, invalid}, {Line, erx_bt_pair:parse(Line)}) || Line <- Invalid].

parse_bond_answers_invalid_for_anything_else_test() ->
    Address = <<" C0:01:02:AB:CD:EF public authenticated">>,
    Invalid = [<<>>, <<"0123456789abcdef0123456789abcde", Address/binary>>,
               <<"0123456789abcdef0123456789abcdef0", Address/binary>>,
               <<"0123456789ABCDEF0123456789abcdef", Address/binary>>,
               <<"0123456789abcdeg0123456789abcdef", Address/binary>>,
               <<"C0:01:02:AB:CD:EF public authenticated">>,
               <<?ID/binary, " C0:01:02:AB:CD:EF private authenticated">>,
               <<?ID/binary, " C0:01:02:AB:CD:EF public authenticated ">>,
               <<?ID/binary, " C0:01:02:AB:CD:EF public">>,
               <<?ID/binary, " C0:01:02:AB:CD:EF public encrypted">>],
    [?assertEqual({Text, invalid}, {Text, erx_bt_pair:parse_bond(Text)}) || Text <- Invalid].

%% An id is its 32 lower-case hexadecimal digits, the whole and nothing less.
id_takes_32_lower_case_digits_alone_test() ->
    ?assertEqual(?ID, erx_bt_pair:id(?ID)),
    [?assertEqual({Text, invalid}, {Text, erx_bt_pair:id(Text)})
     || Text <- [<<>>, binary:part(?ID, 0, 31), <<?ID/binary, "0">>, <<?ID/binary, "\n">>,
                 <<"0123456789ABCDEF0123456789abcdef">>, <<"0123456789abcdeg0123456789abcdef">>,
                 <<" 123456789abcdef0123456789abcdef">>]].

%% A failure's reason on a `failed` line: the phone's Pairing Failed is `peer` whatever its
%% code, and every other reason is itself.
reason_maps_a_failure_to_the_lines_word_test() ->
    ?assertEqual(peer, erx_bt_pair:reason({peer, 16#05})),
    [?assertEqual(Reason, erx_bt_pair:reason(Reason)) || Reason <- type_reasons()].

%% Every reason of the one reason type, which the Security Manager, the store and the
%% window give, makes a `failed` line that parse/1 reads back as itself: the words parse/1
%% reads cover the type, as the module's own debug info states it.
every_reason_of_the_type_reads_back_test() ->
    Reasons = type_reasons(),
    ?assert(lists:member(disconnected, Reasons) andalso lists:member(peer, Reasons)),
    [?assertEqual({Reason, {failed, ?PHONE, Reason}},
                  {Reason, erx_bt_pair:parse(erx_bt_pair:format({failed, ?PHONE, Reason}))})
     || Reason <- Reasons].

%% The atoms of erx_bt_pair:reason(), read from the module's abstract code.
type_reasons() ->
    {ok, {erx_bt_pair, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(erx_bt_pair), [abstract_code]),
    [{type, _, union, Members}] = [Type || {attribute, _, type, {reason, Type, []}} <- Forms],
    [Atom || {atom, _, Atom} <- Members].

%% Bounded reading ----------------------------------------------------------------

a_stream_reads_the_same_at_every_split_test() ->
    Lines = [erx_bt_pair:format(Line) || Line <- every_line()],
    Stream = iolist_to_binary([[Line, $\n] || Line <- Lines]),
    Expected = Lines ++ [eof],
    ?assertEqual(Expected, read_all(Stream, all)),
    ?assertEqual(Expected, read_all(Stream, 1)),
    [?assertEqual({At, Expected}, {At, read_all(Stream, [At])}) || At <- lists:seq(1, byte_size(Stream))].

a_line_of_the_bound_parses_test() ->
    Line = binary:copy(<<"x">>, ?MAX),
    Stream = <<Line/binary, "\nwaiting\n">>,
    [?assertEqual([Line, <<"waiting">>, eof], read_all(Stream, Plan)) || Plan <- [all, 1, [?MAX]]].

an_unterminated_stream_past_the_bound_is_overlong_test() ->
    Stub = stub(binary:copy(<<"x">>, ?MAX + 1), all),
    ?assertEqual(overlong, erx_bt_pair:next(erx_bt_pair:reader(Stub))),
    ?assertEqual([?MAX + 1], asked(Stub)).

a_mebibyte_with_no_newline_costs_one_bounded_buffer_test() ->
    [begin
         Stub = stub(binary:copy(<<"y">>, 1 bsl 20), Plan),
         ?assertEqual(overlong, erx_bt_pair:next(erx_bt_pair:reader(Stub))),
         Asked = asked(Stub),
         ?assert(lists:all(fun(Count) -> Count =< ?MAX + 1 end, Asked)),
         ?assert(served(Stub) =< ?MAX + 1)
     end || Plan <- [all, 1, [7]]].

after_a_line_a_read_asks_only_for_what_the_bound_leaves_test() ->
    Stub = stub(<<"waiting\nwait 12\n">>, [10]),
    {line, <<"waiting">>, Reader} = erx_bt_pair:next(erx_bt_pair:reader(Stub)),
    {line, <<"wait 12">>, _} = erx_bt_pair:next(Reader),
    ?assertEqual([?MAX + 1, ?MAX + 1 - byte_size(<<"wa">>)], asked(Stub)).

a_tail_with_no_newline_is_truncated_test() ->
    ?assertEqual([<<"waiting">>, {error, truncated}], read_all(<<"waiting\nwait 1">>, all)).

a_read_error_ends_the_reading_test() ->
    ?assertEqual({error, eio}, erx_bt_pair:next(erx_bt_pair:reader(stub({reply, {error, eio}}, all)))).

a_read_of_nothing_or_of_more_than_asked_is_refused_test() ->
    Long = <<(binary:copy(<<"a">>, 1000))/binary, "\nwaiting\n">>,
    [?assertEqual({error, einval}, erx_bt_pair:next(erx_bt_pair:reader(stub({reply, Reply}, all))))
     || Reply <- [<<>>, Long, "waiting\n"]].

bonds_reads_every_record_up_to_the_bound_test() ->
    Bonds = [bond(N) || N <- lists:seq(1, ?ERX_BT_BONDS_MAX)],
    Text = iolist_to_binary([[erx_bt_pair:format_bond(Bond), $\n] || Bond <- Bonds]),
    ?assertEqual({ok, Bonds}, erx_bt_pair:bonds(stub(Text, 1))),
    ?assertEqual({ok, []}, erx_bt_pair:bonds(stub(<<>>, all))).

bonds_refuses_one_record_more_than_the_bound_test() ->
    Bonds = [bond(N) || N <- lists:seq(1, ?ERX_BT_BONDS_MAX + 1)],
    Text = iolist_to_binary([[erx_bt_pair:format_bond(Bond), $\n] || Bond <- Bonds]),
    ?assertEqual(overlong, erx_bt_pair:bonds(stub(Text, all))).

bonds_refuses_a_line_that_is_no_record_test() ->
    Text = <<(erx_bt_pair:format_bond(bond(1)))/binary, "\nwaiting\n">>,
    ?assertEqual(invalid, erx_bt_pair:bonds(stub(Text, all))),
    ?assertEqual(overlong, erx_bt_pair:bonds(stub(binary:copy(<<"z">>, 4096), all))).

bond(N) ->
    Id = list_to_binary(io_lib:format("~32.16.0b", [N])),
    #{id => Id, address => <<0, 16#1B, 16#DC, 0, 0, N>>, type => public, level => authenticated}.

%% Every result of next/1 over Stream served by Plan until it ends, each line by its text.
read_all(Stream, Plan) ->
    collect(erx_bt_pair:reader(stub(Stream, Plan))).

collect(Reader) ->
    case erx_bt_pair:next(Reader) of
        {line, Line, Next} -> [Line | collect(Next)];
        Ended -> [Ended]
    end.

stub(Data, Plan) -> erx_bt_pair_stub:start(Data, Plan).
asked(Stub) -> erx_bt_pair_stub:asked(Stub).
served(Stub) -> erx_bt_pair_stub:served(Stub).
