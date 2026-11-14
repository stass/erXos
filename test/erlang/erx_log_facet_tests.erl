%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The EUnit cases of the log facet's request decoder, erx_log_facet:decode/1
%% (docs/design-log.md, "Verification and testing", facet bounds): a write of
%% 16 records, each level and a 4,096-byte text, is taken, and 17 records, a
%% 4,097-byte text, a level that is not one of the eight and every other shape
%% are refused with {error, badarg}. The bounds are the design's, restated
%% here rather than read from the generated ABI, so a wrong limit there fails
%% too.
-module(erx_log_facet_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WRITE_MAX, 16).
-define(TEXT_MAX, 4096).
-define(LEVELS, [emergency, alert, critical, error, warning, notice, info, debug]).

text(Size) -> binary:copy(<<"a">>, Size).

decode(Records) -> erx_log_facet:decode({write, Records}).

%% Every level, an empty text and one of the longest, up to 16 records in one
%% write, are taken as they are.
takes_writes_within_the_bounds_test() ->
    Full = [{Level, text(?TEXT_MAX)} || Level <- ?LEVELS] ++ [{Level, <<>>} || Level <- ?LEVELS],
    ?assertEqual(?WRITE_MAX, length(Full)),
    ?assertEqual({ok, Full}, decode(Full)),
    ?assertEqual({ok, []}, decode([])),
    ?assertEqual({ok, [{info, <<"hello">>}]}, decode([{info, <<"hello">>}])).

%% A write of 17 records is refused, wherever the records are.
refuses_seventeen_records_test() ->
    ?assertEqual({error, badarg}, decode(lists:duplicate(?WRITE_MAX + 1, {info, <<"x">>}))),
    ?assertEqual({error, badarg}, decode(lists:duplicate(?WRITE_MAX + 1, {info, <<>>}))).

%% A text one byte past 4,096 is refused, as the first record or the last.
refuses_a_text_past_the_bound_test() ->
    Long = {notice, text(?TEXT_MAX + 1)},
    ?assertEqual({error, badarg}, decode([Long])),
    ?assertEqual({error, badarg}, decode(lists:duplicate(?WRITE_MAX - 1, {info, <<>>}) ++ [Long])).

%% A level that is not one of the logger's eight is refused: an atom that
%% exists but is no level, the logger's own all and none, a level's name as
%% text, and a number.
refuses_a_level_not_of_the_eight_test() ->
    [?assertEqual({error, badarg}, decode([{info, <<"ok">>}, {Level, <<"text">>}]))
     || Level <- [warn, all, none, fatal, <<"info">>, "info", 7, {info}]].

%% Every other shape is refused: another operation, an extra element, an
%% improper list, a record of another shape, and a text that is not a binary.
refuses_other_shapes_test() ->
    Bad = [{inspect, [], #{}}, {write}, {write, [], extra}, write, [{info, <<>>}],
           {write, #{}}, {write, <<"text">>}, {write, [{info, <<>>} | {info, <<>>}]},
           {write, [{info, <<>>} | nil]}, {write, [{info, <<>>, extra}]}, {write, [{info}]},
           {write, [info]}, {write, [{info, "text"}]}, {write, [{info, <<1:7>>}]},
           {write, [{info, [<<"io">>, <<"list">>]}]}, {write, [{info, text}]}],
    [?assertEqual({error, badarg}, erx_log_facet:decode(Request)) || Request <- Bad].
