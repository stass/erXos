%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The log sink (docs/design-live.md, "The console", Logs): erx_log_h's record of an
%% event, and the line erx_console_log renders for it, with the rate and shape checks.
-module(erx_log_sink_tests).
-include_lib("eunit/include/eunit.hrl").

-export([format/2]).

-define(SOURCE, source(4, <<"system">>)).
%% 12.000345 s after boot.
-define(NOW, 12000345678).
-define(HANDLER, #{formatter => {logger_formatter, #{legacy_header => true, single_line => false}}}).

source(Id, Name) ->
    #{id => Id, principal => 1, name => Name}.

%% logger:error/2 as the logger hands it to a handler.
event(Format, Args) ->
    #{level => error, msg => {Format, Args}, meta => #{time => logger:timestamp(), pid => self()}}.

line(Record) ->
    {line, Line, _State} = erx_console_log:accept(Record, ?SOURCE, ?NOW, erx_console_log:new()),
    iolist_to_binary(Line).

%% The test of the package: an event whose text holds a tab, an escape sequence and a
%% newline reaches the console as one line with each shown as a token, under the
%% domain's head, and no control byte but the line's CR-LF.
a_logged_error_reaches_the_console_escaped_test() ->
    Record = erx_log_h:record(event("tab\there esc\e[31mred nl~s", ["\nend"]), ?HANDLER),
    ?assertEqual(<<"12.000345 error domain 4 principal 1 system: "
                   "tab<U+0009>here esc<U+001B>[31mred nl, end\r\n">>, line(Record)).

a_record_of_the_domain_s_own_making_is_escaped_test() ->
    Line = line({log, warning, <<"a\tb\e]8;;x\e\\c\nd\r">>}),
    ?assertEqual(<<"12.000345 warning domain 4 principal 1 system: "
                   "a<U+0009>b<U+001B>]8;;x<U+001B>\\c<U+000A>d<U+000D>\r\n">>, Line),
    ?assertEqual([], [Byte || <<Byte>> <= binary:part(Line, 0, byte_size(Line) - 2),
                              Byte < 16#20 orelse Byte =:= 16#7F]).

the_name_is_escaped_test() ->
    {line, Line, _} = erx_console_log:accept({log, info, <<"x">>}, source(4, <<"a\e[2Jb">>), ?NOW,
                                             erx_console_log:new()),
    ?assertEqual(<<"12.000345 info domain 4 principal 1 a<U+001B>[2Jb: x\r\n">>, iolist_to_binary(Line)).

the_record_s_text_is_one_line_and_unescaped_test() ->
    ?assertEqual({log, error, <<"tab\there esc\e[31mred nl, end">>},
                 erx_log_h:record(event("tab\there esc\e[31mred nl~s", ["\nend"]), ?HANDLER)).

a_long_text_is_cut_at_a_character_and_marked_test() ->
    {log, error, Text} = erx_log_h:record(event("~ts", [lists:duplicate(3000, 16#E9)]), ?HANDLER),
    ?assertEqual(4095, byte_size(Text)),
    ?assertMatch(<<_:4092/binary, "...">>, Text),
    ?assert(is_binary(unicode:characters_to_binary(Text))),
    ?assertMatch({line, _, _}, erx_console_log:accept({log, error, Text}, ?SOURCE, ?NOW, erx_console_log:new())).

a_failing_formatter_says_so_test() ->
    {log, error, Text} = erx_log_h:record(event("x", []), #{formatter => {no_such_formatter, #{}}}),
    ?assertMatch(<<"erx_log_h: formatter no_such_formatter failed: ", _/binary>>, Text).

other_shapes_are_dropped_and_counted_test() ->
    Refused = [{log, nonsense, <<"x">>}, {log, error, "list"}, {log, error, binary:copy(<<"x">>, 4097)},
               {log, error}, {other, error, <<"x">>}],
    State = lists:foldl(fun(Message, Acc) ->
                                {dropped, Next} = erx_console_log:accept(Message, ?SOURCE, ?NOW, Acc),
                                Next
                        end, erx_console_log:new(), Refused),
    {line, Line, _} = erx_console_log:accept({log, error, <<"ok">>}, ?SOURCE, ?NOW, State),
    ?assertEqual(<<"12.000345 error domain 4 principal 1 dropped 5 system: ok\r\n">>, iolist_to_binary(Line)).

%% Each record is charged its whole line: four lines of 4000 bytes of text and a head
%% fit in 16 KiB, a fifth does not, another domain is counted apart, and the next
%% second takes lines again and says how many were dropped.
sixteen_kib_of_lines_a_second_per_domain_test() ->
    Text = binary:copy(<<"x">>, 4000),
    State = lists:foldl(fun(_, Acc) ->
                                {line, _, Next} = erx_console_log:accept({log, info, Text}, ?SOURCE, ?NOW, Acc),
                                Next
                        end, erx_console_log:new(), lists:seq(1, 4)),
    {dropped, Over} = erx_console_log:accept({log, info, Text}, ?SOURCE, ?NOW, State),
    ?assertMatch({line, _, _}, erx_console_log:accept({log, info, Text}, source(5, <<"system">>), ?NOW, Over)),
    {line, Line, _} = erx_console_log:accept({log, info, <<"y">>}, ?SOURCE, ?NOW + 1000000000, Over),
    ?assertEqual(<<"13.000345 info domain 4 principal 1 dropped 1 system: y\r\n">>, Line).

%% Empty records and text the escape lengthens are charged what they write.
the_rate_counts_what_is_written_test() ->
    {Lines, _} = written(erx_console_log:new(), {log, info, <<>>}, 0),
    ?assert(Lines * byte_size(line({log, info, <<>>})) =< 16384),
    ?assert(Lines < 16384 div 40),
    {Escaped, _} = written(erx_console_log:new(), {log, info, binary:copy(<<27>>, 1000)}, 0),
    ?assertEqual(2, Escaped).

%% How many copies of Record one second of the rate takes.
written(State, Record, Count) ->
    case erx_console_log:accept(Record, ?SOURCE, ?NOW, State) of
        {line, _, Next} -> written(Next, Record, Count + 1);
        {dropped, Next} -> {Count, Next}
    end.

%% A formatter whose failure holds a character past Latin-1 still leaves a record, so
%% log/2 does not raise and the logger keeps the handler.
a_formatter_failing_with_any_reason_leaves_a_record_test() ->
    {log, error, Text} = erx_log_h:record(event("x", []), #{formatter => {?MODULE, #{}}}),
    ?assertMatch(<<"erx_log_h: formatter erx_log_sink_tests failed: ", _/binary>>, Text),
    ?assert(is_binary(unicode:characters_to_binary(Text))).

format(_Event, _Config) ->
    error(list_to_atom([128512])).
