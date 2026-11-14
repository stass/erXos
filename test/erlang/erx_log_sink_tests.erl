%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The log sink (docs/design-live.md, "The console", Logs): erx_log_h's record of an
%% event, and the line the log service makes of it (erx_syslog_core:line/5) as the
%% console writes it, ended in CR-LF; the rate's cases are erx_syslog_core_tests'.
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

%% The line the log service makes of the record, as the console writes it.
line(Record) ->
    line(Record, ?SOURCE).

line({log, Level, Text}, #{id := Id, principal := Principal, name := Name}) ->
    <<(erx_syslog_core:line(?NOW, Id, Principal, Name, {Level, Text}))/binary, "\r\n">>.

%% The test of the package: an event whose text holds a tab, an escape sequence and a
%% newline reaches the console as one line with each shown as a token, under the
%% domain's head, and no control byte but the line's CR-LF.
a_logged_error_reaches_the_console_escaped_test() ->
    Record = erx_log_h:record(event("tab\there esc\e[31mred nl~s", ["\nend"]), ?HANDLER),
    ?assertEqual(<<"12.000345 error domain 4 principal 1 system: "
                   "tab<U+0009>here esc<U+001B>[31mred nl, end\r\n">>, line(Record)).

%% The system domain's own records name its principal unknown until the domain service
%% has named the system principal, rather than a number the console guessed.
an_unknown_principal_is_shown_as_unknown_test() ->
    Source = (source(4, <<"system">>))#{principal => unknown},
    ?assertEqual(<<"12.000345 notice domain 4 principal unknown system: up\r\n">>,
                 line({log, notice, <<"up">>}, Source)).

a_record_of_the_domain_s_own_making_is_escaped_test() ->
    Line = line({log, warning, <<"a\tb\e]8;;x\e\\c\nd\r">>}),
    ?assertEqual(<<"12.000345 warning domain 4 principal 1 system: "
                   "a<U+0009>b<U+001B>]8;;x<U+001B>\\c<U+000A>d<U+000D>\r\n">>, Line),
    ?assertEqual([], [Byte || <<Byte>> <= binary:part(Line, 0, byte_size(Line) - 2),
                              Byte < 16#20 orelse Byte =:= 16#7F]).

the_name_is_escaped_test() ->
    ?assertEqual(<<"12.000345 info domain 4 principal 1 a<U+001B>[2Jb: x\r\n">>,
                 line({log, info, <<"x">>}, source(4, <<"a\e[2Jb">>))).

the_record_s_text_is_one_line_and_unescaped_test() ->
    ?assertEqual({log, error, <<"tab\there esc\e[31mred nl, end">>},
                 erx_log_h:record(event("tab\there esc\e[31mred nl~s", ["\nend"]), ?HANDLER)).

a_long_text_is_cut_at_a_character_and_marked_test() ->
    {log, error, Text} = erx_log_h:record(event("~ts", [lists:duplicate(3000, 16#E9)]), ?HANDLER),
    ?assertEqual(4095, byte_size(Text)),
    ?assertMatch(<<_:4092/binary, "...">>, Text),
    ?assert(is_binary(unicode:characters_to_binary(Text))),
    ?assertMatch(<<"12.000345 error domain 4 principal 1 system: ", _/binary>>, line({log, error, Text})).

a_failing_formatter_says_so_test() ->
    {log, error, Text} = erx_log_h:record(event("x", []), #{formatter => {no_such_formatter, #{}}}),
    ?assertMatch(<<"erx_log_h: formatter no_such_formatter failed: ", _/binary>>, Text).

%% A formatter whose failure holds a character past Latin-1 still leaves a record, so
%% log/2 does not raise and the logger keeps the handler.
a_formatter_failing_with_any_reason_leaves_a_record_test() ->
    {log, error, Text} = erx_log_h:record(event("x", []), #{formatter => {?MODULE, #{}}}),
    ?assertMatch(<<"erx_log_h: formatter erx_log_sink_tests failed: ", _/binary>>, Text),
    ?assert(is_binary(unicode:characters_to_binary(Text))).

format(_Event, _Config) ->
    error(list_to_atom([128512])).
