%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_9p_tests).
-moduledoc """
EUnit cases of the host link's 9P bridge: `erx_hostlink_9p`'s pure core,
driven with 9P2000.L bytes as the host sends them, and `erx_hostlink_files`,
the bridge process, over a real `erx_fs` grant of erx_fs_test_tree, whose
tree is named `test`. The core cases check each effect; the grant cases
check what a host reads back.
""".

-include_lib("eunit/include/eunit.hrl").

-define(NOFID, 16#ffffffff).
-define(MSIZE, 8192).
-define(RDONLY, 0).
-define(RDWR, 2).

%%% The pure core ---------------------------------------------------------

%% A bridge whose trees are a and b, served by two stand-in grants.
core() ->
    core(#{}).

core(Options) ->
    A = spawn(fun() -> receive stop -> ok end end),
    B = spawn(fun() -> receive stop -> ok end end),
    Trees = fun(<<"a">>) -> {ok, A}; (<<"b">>) -> {ok, B}; (_) -> error end,
    {erx_hostlink_9p:new(Options#{trees => Trees, alias => fun make_ref/0}), A, B}.

%% One host message with the drawn fid Drawn; the alias is that of the one
%% message the bridge sent a grant for it, or none.
host(Tag, Request, Drawn, Bridge) ->
    {Bridge1, Effects} = erx_hostlink_9p:step({host, erx_9p:encode(Tag, Request), Drawn}, Bridge),
    Alias = case sent(Effects) of
                [{_, Sent, _}] -> Sent;
                _ -> none
            end,
    {Bridge1, Alias, Effects}.

%% The one 9P2000.L reply among Effects, decoded.
answer(Effects) ->
    [Bytes] = [Bytes || {host, Bytes} <- Effects],
    {ok, Tag, {reply, _, Reply}} = erx_9p:decode(Bytes, ?MSIZE),
    {Tag, Reply}.

answers(Effects) ->
    [begin {ok, Tag, {reply, _, Reply}} = erx_9p:decode(Bytes, ?MSIZE), {Tag, Reply} end
     || {host, Bytes} <- Effects].

%% What the bridge sent to a grant among Effects.
sent(Effects) ->
    [{Grant, Alias, Request} || {grant, Grant, Alias, Request} <- Effects].

versioned(Bridge) ->
    {Bridge1, _, Effects} = host(1, {version, ?MSIZE, <<"9P2000.L">>}, 0, Bridge),
    {1, {ok, ?MSIZE, <<"9P2000.L">>}} = answer(Effects),
    Bridge1.

%% A session with fid 1 attached to tree a as grant fid 101.
attached() ->
    {Bridge, A, B} = core(),
    {Bridge1, Alias, Effects} = host(2, {attach, 1, ?NOFID, <<"u">>, <<"a">>, 0}, 101, versioned(Bridge)),
    [{A, Alias, {attach, 101, ?NOFID, <<"u">>, <<"a">>, 0}}] = sent(Effects),
    {Bridge2, []} = reply(Alias, {ok, {16#80, 0, 1}}, Bridge1, 2),
    {Bridge2, A, B}.

%% The grant's reply to Alias; returns the bridge and the host's answers, all
%% of which must carry Tag.
reply(Alias, Reply, Bridge, Tag) ->
    {Bridge1, Effects} = erx_hostlink_9p:step({reply, Alias, Reply}, Bridge),
    Answers = answers(Effects),
    [Tag = T || {T, _} <- Answers],
    {Bridge1, [R || {_, R} <- Answers, R =/= {ok, {16#80, 0, 1}}]}.

version_takes_the_smaller_msize_test() ->
    {Bridge, _, _} = core(),
    {_, _, Effects} = host(1, {version, 65560, <<"9P2000.L">>}, 0, Bridge),
    ?assertEqual({1, {ok, ?MSIZE, <<"9P2000.L">>}}, answer(Effects)),
    {Small, _, Effects1} = host(1, {version, 4096, <<"9P2000.L">>}, 0, Bridge),
    ?assertEqual({1, {ok, 4096, <<"9P2000.L">>}}, answer(Effects1)),
    ?assertMatch(#{msize := 4096}, erx_hostlink_9p:info(Small)).

version_below_4096_and_other_protocols_open_no_session_test() ->
    {Bridge, _, _} = core(),
    {_, _, Effects} = host(1, {version, 4095, <<"9P2000.L">>}, 0, Bridge),
    ?assertEqual({1, {error, einval}}, answer(Effects)),
    {Other, _, Effects1} = host(1, {version, ?MSIZE, <<"9P2000">>}, 0, Bridge),
    ?assertEqual({1, {ok, ?MSIZE, <<"unknown">>}}, answer(Effects1)),
    {_, _, Effects2} = host(2, {attach, 1, ?NOFID, <<"u">>, <<"a">>, 0}, 101, Other),
    ?assertEqual({2, {error, einval}}, answer(Effects2)).

a_version_after_one_that_opened_no_session_is_served_test() ->
    {Bridge, _, _} = core(),
    {Unknown, _, _} = host(1, {version, ?MSIZE, <<"9P2000">>}, 0, Bridge),
    {Small, _, _} = host(1, {version, 4095, <<"9P2000.L">>}, 0, Unknown),
    {Opened, _, Effects} = host(1, {version, ?MSIZE, <<"9P2000.L">>}, 0, Small),
    ?assertEqual({1, {ok, ?MSIZE, <<"9P2000.L">>}}, answer(Effects)),
    ?assertMatch(#{msize := ?MSIZE}, erx_hostlink_9p:info(Opened)).

a_version_in_a_session_is_refused_and_changes_nothing_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    %% Refused on its own tag: nothing is sent, clunked or forgotten, and the
    %% msize stays.
    {Bridge2, _, Effects} = host(5, {version, 4096, <<"9P2000.L">>}, 0, Bridge1),
    ?assertMatch([{host, _}], Effects),
    ?assertEqual({5, {error, einval}}, answer(Effects)),
    ?assertMatch(#{msize := ?MSIZE, fids := 1, tags := 1, requests := 1, awaited := 1},
                 erx_hostlink_9p:info(Bridge2)),
    %% The pending read is still answered on its tag.
    {Bridge3, E3} = erx_hostlink_9p:step({reply, ReadAlias, {ok, <<"ab">>}}, Bridge2),
    ?assertEqual([{3, {ok, <<"ab">>}}], answers(E3)),
    ?assertMatch(#{fids := 1, tags := 0}, erx_hostlink_9p:info(Bridge3)).

a_version_on_a_tag_in_use_is_discarded_and_with_every_tag_in_use_refused_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, _, _} = host(3, {read, 1, 0, 1}, 0, Bridge),
    {Bridge2, _, OnPending} = host(3, {version, ?MSIZE, <<"9P2000.L">>}, 0, Bridge1),
    ?assertEqual([], OnPending),
    ?assertMatch(#{counts := #{tag_in_use := 1}, tags := 1}, erx_hostlink_9p:info(Bridge2)),
    %% A refusal takes no tag of the bound, so it is answered with all 64 in use.
    Full = lists:foldl(fun(Tag, Acc) -> element(1, host(Tag, {flush, 3}, 0, Acc)) end,
                       Bridge1, lists:seq(10, 72)),
    ?assertMatch(#{tags := 64}, erx_hostlink_9p:info(Full)),
    {Still, _, AllInUse} = host(7, {version, ?MSIZE, <<"9P2000.L">>}, 0, Full),
    ?assertEqual({7, {error, einval}}, answer(AllInUse)),
    ?assertMatch(#{tags := 64, fids := 1}, erx_hostlink_9p:info(Still)).

nothing_is_served_before_version_test() ->
    {Bridge, _, _} = core(),
    {_, _, Effects} = host(2, {attach, 1, ?NOFID, <<"u">>, <<"a">>, 0}, 101, Bridge),
    ?assertEqual({2, {error, einval}}, answer(Effects)),
    ?assertMatch([{host, _}], Effects).

auth_is_not_served_test() ->
    {Bridge, _, _} = core(),
    {_, _, Effects} = host(2, {auth, 7, <<"u">>, <<"a">>, 0}, 0, versioned(Bridge)),
    ?assertEqual({2, {error, enotsup}}, answer(Effects)).

attach_names_only_listed_trees_test() ->
    {Bridge, _, _} = core(),
    {_, _, Effects} = host(2, {attach, 1, ?NOFID, <<"u">>, <<"etc">>, 0}, 101, versioned(Bridge)),
    ?assertEqual({2, {error, enoent}}, answer(Effects)),
    {_, _, Effects1} = host(2, {attach, 1, 5, <<"u">>, <<"a">>, 0}, 101, versioned(Bridge)),
    ?assertEqual({2, {error, einval}}, answer(Effects1)).

walk_renames_fids_and_a_failed_walk_frees_its_new_fid_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, Alias, Effects} = host(3, {walk, 1, 2, [<<"x">>, <<"y">>]}, 102, Bridge),
    ?assertEqual([{A, Alias, {walk, 101, 102, [<<"x">>, <<"y">>]}}], sent(Effects)),
    ?assertMatch(#{fids := 2}, erx_hostlink_9p:info(Bridge1)),
    %% Stopped after one name: the new fid was never made.
    {Bridge2, [{ok, [{0, 0, 9}]}]} = reply(Alias, {ok, [{0, 0, 9}]}, Bridge1, 3),
    ?assertMatch(#{fids := 1, tags := 0, requests := 0}, erx_hostlink_9p:info(Bridge2)),
    {_, _, Effects2} = host(4, {lopen, 2, ?RDONLY}, 103, Bridge2),
    ?assertEqual({4, {error, ebadf}}, answer(Effects2)).

walk_in_place_keeps_its_grant_fid_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, Alias, Effects} = host(3, {walk, 1, 1, [<<"x">>]}, 102, Bridge),
    ?assertEqual([{A, Alias, {walk, 101, 101, [<<"x">>]}}], sent(Effects)),
    {Bridge2, _} = reply(Alias, {error, enoent}, Bridge1, 3),
    ?assertMatch(#{fids := 1}, erx_hostlink_9p:info(Bridge2)).

pipelined_requests_reach_the_new_fid_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, _, _} = host(3, {walk, 1, 2, [<<"f">>]}, 102, Bridge),
    {_, Alias, Effects} = host(4, {lopen, 2, ?RDONLY}, 103, Bridge1),
    ?assertEqual([{A, Alias, {lopen, 102, ?RDONLY}}], sent(Effects)).

fid_in_use_unknown_fid_and_the_pool_test() ->
    {Bridge0, A, _} = core(#{pool => 2}),
    {Bridge1, Alias, _} = host(2, {attach, 1, ?NOFID, <<"u">>, <<"a">>, 0}, 101, versioned(Bridge0)),
    {Bridge2, _} = reply(Alias, {ok, {16#80, 0, 1}}, Bridge1, 2),
    {_, _, InUse} = host(3, {attach, 1, ?NOFID, <<"u">>, <<"a">>, 0}, 102, Bridge2),
    ?assertEqual({3, {error, einval}}, answer(InUse)),
    {_, _, Unknown} = host(3, {read, 9, 0, 10}, 102, Bridge2),
    ?assertEqual({3, {error, ebadf}}, answer(Unknown)),
    {Bridge3, _, Walked} = host(3, {walk, 1, 2, []}, 102, Bridge2),
    ?assertMatch([{A, _, {walk, 101, 102, []}}], sent(Walked)),
    {_, _, Full} = host(4, {walk, 1, 3, []}, 103, Bridge3),
    ?assertEqual({4, {error, emfile}}, answer(Full)).

two_trees_in_one_request_are_exdev_test() ->
    {Bridge, _, B} = attached(),
    {Bridge1, Alias, Effects} = host(3, {attach, 2, ?NOFID, <<"u">>, <<"b">>, 0}, 102, Bridge),
    ?assertMatch([{B, _, _}], sent(Effects)),
    {Bridge2, _} = reply(Alias, {ok, {16#80, 0, 1}}, Bridge1, 3),
    {_, _, Effects1} = host(4, {renameat, 1, <<"x">>, 2, <<"y">>}, 103, Bridge2),
    ?assertEqual({4, {error, exdev}}, answer(Effects1)).

clunk_ends_the_fid_when_sent_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, Alias, Effects} = host(3, {clunk, 1}, 102, Bridge),
    ?assertEqual([{A, Alias, {clunk, 101}}], sent(Effects)),
    ?assertMatch(#{fids := 0}, erx_hostlink_9p:info(Bridge1)),
    ?assertMatch({_, [ok]}, reply(Alias, ok, Bridge1, 3)).

reads_are_cut_to_the_msize_and_iounit_follows_it_test() ->
    {Bridge, A, _} = attached(),
    {_, _, Effects} = host(3, {read, 1, 0, 65536}, 102, Bridge),
    ?assertEqual([{A, element(2, hd(sent(Effects))), {read, 101, 0, ?MSIZE - 11}}], sent(Effects)),
    {Bridge1, Alias, _} = host(4, {lopen, 1, ?RDONLY}, 103, Bridge),
    {_, [{ok, {0, 0, 4}, Iounit}]} = reply(Alias, {ok, {0, 0, 4}, 65536}, Bridge1, 4),
    ?assertEqual(?MSIZE - 24, Iounit).

a_reply_that_fails_its_check_is_eio_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, Alias, _} = host(3, {read, 1, 0, 4}, 102, Bridge),
    ?assertMatch({_, [{error, eio}]}, reply(Alias, {ok, <<"12345">>}, Bridge1, 3)),
    {Bridge2, Alias2, _} = host(3, {read, 1, 0, 4}, 102, Bridge),
    ?assertMatch({_, [{error, eio}]}, reply(Alias2, {ok, not_a_binary}, Bridge2, 3)).

a_failed_check_on_a_new_fid_clunks_what_the_grant_may_hold_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, Alias, _} = host(3, {walk, 1, 2, [<<"x">>]}, 102, Bridge),
    {Bridge2, Effects} = erx_hostlink_9p:step({reply, Alias, {ok, [{0, 0, 1}, {0, 0, 2}]}}, Bridge1),
    ?assert(lists:member({clunk, A, 102}, Effects)),
    ?assertEqual([{3, {error, eio}}], answers(Effects)),
    ?assertMatch(#{fids := 1}, erx_hostlink_9p:info(Bridge2)).

discarded_messages_are_counted_not_answered_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, []} = erx_hostlink_9p:step({host, <<1, 2, 3>>, 0}, Bridge),
    {Bridge2, []} = erx_hostlink_9p:step({host, erx_9p:encode(3, {reply, clunk, ok}), 0}, Bridge1),
    {Bridge3, _, _} = host(3, {read, 1, 0, 4}, 102, Bridge2),
    {Bridge4, _, Repeat} = host(3, {read, 1, 0, 4}, 103, Bridge3),
    ?assertEqual([], answers(Repeat)),
    ?assertMatch(#{counts := #{malformed := 1, not_request := 1, tag_in_use := 1}},
                 erx_hostlink_9p:info(Bridge4)).

requests_beyond_the_bound_fail_and_a_clunk_still_ends_test() ->
    {Bridge, A, _} = attached(),
    Full = lists:foldl(fun(Tag, Acc) -> element(1, host(Tag, {read, 1, 0, 1}, 0, Acc)) end,
                       Bridge, lists:seq(10, 41)),
    {_, _, Refused} = host(50, {read, 1, 0, 1}, 0, Full),
    ?assertEqual({50, {error, emfile}}, answer(Refused)),
    {Clunked, _, Effects} = host(51, {clunk, 1}, 0, Full),
    ?assertEqual({51, {error, emfile}}, answer(Effects)),
    ?assert(lists:member({clunk, A, 101}, Effects)),
    ?assertMatch(#{fids := 0}, erx_hostlink_9p:info(Clunked)).

flush_of_an_unknown_tag_is_answered_at_once_test() ->
    {Bridge, _, _} = attached(),
    {_, _, Effects} = host(3, {flush, 77}, 0, Bridge),
    ?assertEqual([{3, ok}], answers(Effects)),
    ?assertEqual([], sent(Effects)).

flush_waits_for_the_grant_and_follows_the_reply_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, FlushAlias, Effects} = host(4, {flush, 3}, 0, Bridge1),
    ?assertEqual([{A, FlushAlias, {flush, ReadAlias}}], sent(Effects)),
    ?assertEqual([], answers(Effects)),
    {Bridge3, E3} = erx_hostlink_9p:step({reply, ReadAlias, {ok, <<"ab">>}}, Bridge2),
    ?assertEqual([{3, {ok, <<"ab">>}}], answers(E3)),
    {Bridge4, E4} = erx_hostlink_9p:step({reply, FlushAlias, ok}, Bridge3),
    ?assertEqual([{4, ok}], answers(E4)),
    ?assertMatch(#{tags := 0, requests := 0}, erx_hostlink_9p:info(Bridge4)).

flush_of_an_abandoned_request_forgets_it_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {lock, 1, 1, 1, 0, 0, 1, <<"c">>}, 0, Bridge),
    {Bridge2, FlushAlias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, E3} = erx_hostlink_9p:step({reply, FlushAlias, ok}, Bridge2),
    ?assertEqual([{4, ok}], answers(E3)),
    ?assert(lists:member({unalias, ReadAlias}, E3)),
    ?assertMatch(#{tags := 0, requests := 0}, erx_hostlink_9p:info(Bridge3)).

a_refused_flush_waits_for_the_request_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, FlushAlias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, []} = erx_hostlink_9p:step({reply, FlushAlias, {error, emfile}}, Bridge2),
    {Bridge4, E4} = erx_hostlink_9p:step({reply, ReadAlias, {ok, <<>>}}, Bridge3),
    ?assertEqual([{3, {ok, <<>>}}, {4, ok}], answers(E4)),
    ?assertMatch(#{tags := 0}, erx_hostlink_9p:info(Bridge4)).

a_grant_that_ends_fails_its_requests_and_forgets_its_fids_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, _, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, _, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, Effects} = erx_hostlink_9p:step({grant_down, A}, Bridge2),
    ?assertEqual([{3, {error, eio}}, {4, ok}], answers(Effects)),
    ?assertMatch(#{fids := 0, tags := 0, requests := 0}, erx_hostlink_9p:info(Bridge3)).

flush_of_a_flush_at_the_grant_waits_behind_it_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, FlushAlias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, _, Effects} = host(5, {flush, 4}, 0, Bridge2),
    %% Tag 4 may still be answered, so tag 5's answer must not come first,
    %% and one flush of the read is at the grant already.
    ?assertEqual([], Effects),
    {Bridge4, E4} = erx_hostlink_9p:step({reply, ReadAlias, {ok, <<"ab">>}}, Bridge3),
    ?assertEqual([{3, {ok, <<"ab">>}}], answers(E4)),
    {Bridge5, E5} = erx_hostlink_9p:step({reply, FlushAlias, ok}, Bridge4),
    ?assertEqual([{4, ok}, {5, ok}], answers(E5)),
    ?assertMatch(#{tags := 0, requests := 0}, erx_hostlink_9p:info(Bridge5)).

flush_of_a_refused_flush_waits_behind_it_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, FlushAlias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, []} = erx_hostlink_9p:step({reply, FlushAlias, {error, emfile}}, Bridge2),
    %% The read's chain moves along: no flush of it is at the grant, so the
    %% next one goes there, and its answer still waits behind tag 4's.
    {Bridge4, Flush5Alias, Effects} = host(5, {flush, 4}, 0, Bridge3),
    ?assertEqual([{A, Flush5Alias, {flush, ReadAlias}}], sent(Effects)),
    ?assertEqual([], answers(Effects)),
    {Bridge5, E5} = erx_hostlink_9p:step({reply, ReadAlias, {ok, <<>>}}, Bridge4),
    ?assertEqual([{3, {ok, <<>>}}, {4, ok}], answers(E5)),
    {Bridge6, E6} = erx_hostlink_9p:step({reply, Flush5Alias, ok}, Bridge5),
    ?assertEqual([{5, ok}], answers(E6)),
    ?assertMatch(#{tags := 0}, erx_hostlink_9p:info(Bridge6)).

flush_of_an_abandoned_requests_flush_follows_it_test() ->
    {Bridge, _, _} = attached(),
    {Bridge1, _, _} = host(3, {lock, 1, 1, 1, 0, 0, 1, <<"c">>}, 0, Bridge),
    {Bridge2, FlushAlias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, _, _} = host(5, {flush, 4}, 0, Bridge2),
    {Bridge4, E4} = erx_hostlink_9p:step({reply, FlushAlias, ok}, Bridge3),
    ?assertEqual([{4, ok}, {5, ok}], answers(E4)),
    ?assertMatch(#{tags := 0, requests := 0}, erx_hostlink_9p:info(Bridge4)).

two_flushes_of_one_request_answer_in_order_whatever_the_grant_does_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, ReadAlias, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, Flush4Alias, _} = host(4, {flush, 3}, 0, Bridge1),
    %% One flush of the read is at the grant: the second waits.
    {Bridge3, _, Held} = host(5, {flush, 3}, 0, Bridge2),
    ?assertEqual([], Held),
    %% The grant answers the first malformed: the second goes in its place.
    {Bridge4, E4} = erx_hostlink_9p:step({reply, Flush4Alias, junk}, Bridge3),
    [{A, Flush5Alias, {flush, ReadAlias}}] = sent(E4),
    ?assertEqual([], answers(E4)),
    %% The grant abandons the read at the second: both flushes, in order.
    {Bridge5, E5} = erx_hostlink_9p:step({reply, Flush5Alias, ok}, Bridge4),
    ?assertEqual([{4, ok}, {5, ok}], answers(E5)),
    ?assert(lists:member({unalias, ReadAlias}, E5)),
    ?assertMatch(#{tags := 0, requests := 0, awaited := 0}, erx_hostlink_9p:info(Bridge5)).

a_grant_that_ends_answers_a_chain_in_order_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, _, _} = host(3, {read, 1, 0, 4}, 0, Bridge),
    {Bridge2, Flush4Alias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, _, _} = host(5, {flush, 3}, 0, Bridge2),
    {Bridge4, _} = erx_hostlink_9p:step({reply, Flush4Alias, {error, emfile}}, Bridge3),
    {Bridge5, _, _} = host(6, {flush, 3}, 0, Bridge4),
    {Bridge6, Effects} = erx_hostlink_9p:step({grant_down, A}, Bridge5),
    ?assertEqual([{3, {error, eio}}, {4, ok}, {5, ok}, {6, ok}], answers(Effects)),
    ?assertMatch(#{tags := 0, awaited := 0}, erx_hostlink_9p:info(Bridge6)).

an_abandoned_walk_makes_no_fid_test() ->
    {Bridge, A, _} = attached(),
    {Bridge1, WalkAlias, _} = host(3, {walk, 1, 2, [<<"x">>]}, 102, Bridge),
    {Bridge2, FlushAlias, _} = host(4, {flush, 3}, 0, Bridge1),
    {Bridge3, Effects} = erx_hostlink_9p:step({reply, FlushAlias, ok}, Bridge2),
    ?assertEqual([{4, ok}], answers(Effects)),
    ?assert(lists:member({unalias, WalkAlias}, Effects)),
    %% Whatever the grant made of it is clunked, and fid 2 is free again.
    ?assert(lists:member({clunk, A, 102}, Effects)),
    ?assertMatch(#{fids := 1}, erx_hostlink_9p:info(Bridge3)).

requests_and_flushes_share_the_tags_bound_test() ->
    {Bridge, _, _} = attached(),
    Full = lists:foldl(fun(Tag, Acc) -> element(1, host(Tag, {read, 1, 0, 1}, 0, Acc)) end,
                       Bridge, lists:seq(10, 41)),
    Flushed = lists:foldl(fun(Tag, Acc) -> element(1, host(Tag + 100, {flush, Tag}, 0, Acc)) end,
                          Full, lists:seq(10, 41)),
    ?assertMatch(#{tags := 64, requests := 32, flushes := 32}, erx_hostlink_9p:info(Flushed)),
    %% A second flush of a read would take a 65th tag: discarded and counted.
    {Counted, _, Effects} = host(6, {flush, 10}, 0, Flushed),
    ?assertEqual([], Effects),
    ?assertMatch(#{counts := #{tags_full := 1}, tags := 64}, erx_hostlink_9p:info(Counted)).

the_fid_table_holds_256_fids_by_default_test() ->
    {Bridge, _, _} = attached(),
    Walked = lists:foldl(fun(Fid, Acc) ->
                                 {Acc1, Alias, _} = host(3, {walk, 1, Fid, []}, Fid + 100, Acc),
                                 element(1, erx_hostlink_9p:step({reply, Alias, {ok, []}}, Acc1))
                         end, Bridge, lists:seq(2, 256)),
    ?assertMatch(#{fids := 256}, erx_hostlink_9p:info(Walked)),
    {_, _, Full} = host(3, {walk, 1, 257, []}, 357, Walked),
    ?assertEqual({3, {error, emfile}}, answer(Full)).

%%% The trees a build serves ----------------------------------------------

a_development_build_serves_the_designs_trees_test() ->
    ?assertEqual([<<"proc">>, <<"data">>], erx_hostlink_files:default_trees(1)),
    %% A partial boot is a development build's too.
    ?assertEqual([<<"proc">>, <<"data">>], erx_hostlink_files:default_trees(3)).

a_release_build_or_an_unread_manifest_serves_none_test() ->
    ?assertEqual([], erx_hostlink_files:default_trees(0)),
    ?assertEqual([], erx_hostlink_files:default_trees(unknown)),
    ?assertEqual(unknown, erx_hostlink_files:manifest_flags({error, enoent})),
    ?assertEqual(unknown, erx_hostlink_files:manifest_flags({ok, <<"not a manifest">>})).

%%% The bridge process over a real grant ---------------------------------

%% A bridge of tree test, served by an erx_fs grant of erx_fs_test_tree.
bridge(Options) ->
    {ok, Grant} = erx_fs:start_link(erx_fs_test_tree, [], rw),
    unlink(Grant),
    Counter = atomics:new(1, []),
    Draw = fun() -> atomics:add_get(Counter, 1, 1) end,
    Trees = fun(<<"test">>) -> {ok, Grant}; (_) -> error end,
    {Bridge, Ref} = erx_hostlink_files:start(self(), Options#{trees => Trees, draw_fid => Draw}),
    {Bridge, Ref, Grant}.

%% Sends one request and waits for its answer.
call(Bridge, Tag, Request) ->
    Bridge ! {files_in, self(), erx_9p:encode(Tag, Request)},
    receive
        {files_out, Bridge, Bytes} ->
            {ok, Tag, {reply, _, Reply}} = erx_9p:decode(Bytes, ?MSIZE),
            Reply
    after 5000 ->
        erlang:error(no_answer)
    end.

a_host_reads_what_it_wrote_test() ->
    {Bridge, _, Grant} = bridge(#{}),
    {ok, ?MSIZE, <<"9P2000.L">>} = call(Bridge, ?NOFID band 16#ffff, {version, ?MSIZE, <<"9P2000.L">>}),
    {ok, {16#80, _, _}} = call(Bridge, 1, {attach, 10, ?NOFID, <<"u">>, <<"test">>, 0}),
    {ok, [_, _]} = call(Bridge, 2, {walk, 10, 11, [<<"a">>, <<"f">>]}),
    {ok, _, Iounit} = call(Bridge, 3, {lopen, 11, ?RDWR}),
    ?assertEqual(?MSIZE - 24, Iounit),
    Data = << <<(N rem 251)>> || N <- lists:seq(1, 20000) >>,
    lists:foreach(fun(At) ->
                          Piece = binary:part(Data, At, min(4096, 20000 - At)),
                          Size = byte_size(Piece),
                          {ok, Size, unknown} = call(Bridge, 4, {write, 11, At, Piece})
                  end, lists:seq(0, 19999, 4096)),
    ?assertEqual(Data, read_all(Bridge, 11, 0, <<>>)),
    ok = call(Bridge, 6, {clunk, 11}),
    ?assertEqual({error, ebadf}, call(Bridge, 7, {read, 11, 0, 10})),
    exit(Bridge, kill),
    exit(Grant, kill).

read_all(Bridge, Fid, At, Acc) ->
    case call(Bridge, 5, {read, Fid, At, 65536}) of
        {ok, <<>>} -> Acc;
        {ok, Bytes} when byte_size(Bytes) =< ?MSIZE - 11 -> read_all(Bridge, Fid, At + byte_size(Bytes), <<Acc/binary, Bytes/binary>>)
    end.

errors_and_limits_reach_the_host_test() ->
    {Bridge, _, Grant} = bridge(#{pool => 2}),
    {ok, _, _} = call(Bridge, 0, {version, ?MSIZE, <<"9P2000.L">>}),
    ?assertEqual({error, enoent}, call(Bridge, 1, {attach, 10, ?NOFID, <<"u">>, <<"data">>, 0})),
    {ok, _} = call(Bridge, 1, {attach, 10, ?NOFID, <<"u">>, <<"test">>, 0}),
    ?assertEqual({error, enoent}, call(Bridge, 2, {walk, 10, 11, [<<"nothing">>]})),
    ?assertEqual({error, ebadf}, call(Bridge, 2, {read, 10, 0, 1})),
    ?assertEqual({error, eisdir}, call(Bridge, 2, {lopen, 10, ?RDWR})),
    {ok, [_]} = call(Bridge, 3, {walk, 10, 11, [<<"f">>]}),
    ?assertEqual({error, emfile}, call(Bridge, 4, {walk, 10, 12, []})),
    ?assertEqual(ok, call(Bridge, 5, {flush, 3})),
    exit(Bridge, kill),
    exit(Grant, kill).

the_bridge_ends_with_its_link_test() ->
    Link = spawn(fun() -> receive stop -> ok end end),
    {Bridge, Ref} = erx_hostlink_files:start(Link, #{trees => fun(_) -> error end,
                                                      draw_fid => fun() -> 1 end}),
    Link ! stop,
    receive {'DOWN', Ref, process, Bridge, Reason} -> ?assertEqual(normal, Reason)
    after 5000 -> erlang:error(bridge_outlived_its_link)
    end.

the_bridges_end_clunks_its_fids_test() ->
    {ok, Grant} = erx_fs:start_link(erx_fs_test_tree, [{observer, self()}], rw),
    unlink(Grant),
    Counter = atomics:new(1, []),
    {Bridge, Ref} = erx_hostlink_files:start(self(), #{trees => fun(_) -> {ok, Grant} end,
                                                        draw_fid => fun() -> atomics:add_get(Counter, 1, 1) end}),
    {ok, _, _} = call(Bridge, 0, {version, ?MSIZE, <<"9P2000.L">>}),
    {ok, _} = call(Bridge, 1, {attach, 10, ?NOFID, <<"u">>, <<"test">>, 0}),
    {ok, [_]} = call(Bridge, 2, {walk, 10, 11, [<<"f">>]}),
    {ok, _, _} = call(Bridge, 3, {lopen, 11, ?RDONLY}),
    flush_tree_calls(),
    exit(Bridge, kill),
    receive {'DOWN', Ref, process, Bridge, _} -> ok end,
    %% The grant sees its owner end and clunks the open file for it.
    receive {tree_call, clunk} -> ok
    after 5000 -> erlang:error(the_open_file_outlived_the_bridge)
    end,
    exit(Grant, kill).

flush_tree_calls() ->
    receive {tree_call, _} -> flush_tree_calls()
    after 0 -> ok
    end.
