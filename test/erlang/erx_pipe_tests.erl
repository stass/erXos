%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of the pipe server's decisions, erx_pipe:step/2
%% (docs/design-pipes.md, "The pipe server"): what each first-tier event
%% makes, installs, reports and closes, and each event's refusal: the
%% quota and the 32-bit numbers with enfile, the 65th read end with
%% emfile, an end its requester does not hold with ebadf, and a notice
%% from a holder of no such end, or not due, ignored without a change.
%% erx_pipe_explore checks every order of these events.

-module(erx_pipe_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(A, {program, 7}).
-define(B, {program, 8}).
-define(C, {program, 9}).

%% A pipe of ?A: read end 1 at index 0, write end 2 with lane 1.
pipe(Holder) ->
    pipe(Holder, #{}).

pipe(Holder, Opts) ->
    {S, _} = erx_pipe:step(erx_pipe:new(Opts), {pipe, Holder, []}),
    S.

step(S, Event) ->
    erx_pipe:step(S, Event).

reply(Actions) ->
    [Reply] = [R || {reply, R} <- Actions],
    Reply.

reports(Actions) ->
    [{H, R} || {report, H, R} <- Actions].

closes(Actions) ->
    [O || {close, O} <- Actions].

%% An event that changes nothing: the same records, no action.
unchanged(S, Event) ->
    ?assertEqual({S, []}, step(S, Event)).

refused(S, Event, Reason) ->
    {S1, Actions} = step(S, Event),
    ?assertEqual(S, S1),
    ?assertEqual([{reply, {error, Reason}}], Actions).

pipe_makes_both_ends_test() ->
    {S, Actions} = step(erx_pipe:new(#{}), {pipe, ?A, [cloexec]}),
    Read = {pipe, read, {1, 1},
            #{rix => 0, lock => {lock, 1}, wends => 1,
              writers => [{1, {ring, 1, 1}, {rpage, 1, 1}, 65536, {open, {bell, 1, 2}}}],
              readers => []}},
    Write = {pipe, write, {1, 2},
             #{wend => 1, ring => {ring, 1, 1}, rpage => {rpage, 1, 1}, size => 65536,
               readers => [{0, {bell, 1, 1}}]}},
    ?assertEqual([{make_lane, {ring, 1, 1}, {rpage, 1, 1}, 65536},
                  {make_bell, {bell, 1, 1}, ?A, erx_pipe:label(1, 1)},
                  {make_bell, {bell, 1, 2}, ?A, erx_pipe:label(1, 2)},
                  {make_lock, {lock, 1}},
                  {store_wends, {lock, 1}, 1},
                  {reply, {ok, Read, Write}}], Actions),
    ?assertEqual(#{lanes => 1, next_pipe => 2,
                   pipes => #{1 => #{wends => 1, next_end => 3,
                                     writers => #{1 => #{end_id => 2, holder => ?A,
                                                         size => 65536, state => open}},
                                     readers => #{0 => #{end_id => 1, holder => ?A}}}}},
                 erx_pipe:view(S)).

a_session_process_end_takes_its_registered_label_test() ->
    Holder = {process, self()},
    {_, Actions} = step(erx_pipe:new(#{}), {pipe, Holder, []}),
    ?assertEqual([registered, registered], [L || {make_bell, _, _, L} <- Actions]).

pipes_are_numbered_from_one_and_never_reused_test() ->
    S1 = pipe(?A),
    {S2, _} = step(S1, {closed, ?A, 1, 1}),
    {S3, _} = step(S2, {closed, ?A, 1, 2}),
    ?assertEqual(#{}, maps:get(pipes, erx_pipe:view(S3))),
    {_, Actions} = step(S3, {pipe, ?A, []}),
    ?assertMatch({ok, {pipe, read, {2, 1}, _}, {pipe, write, {2, 2}, _}}, reply(Actions)).

a_pipe_past_the_quota_is_refused_test() ->
    S = pipe(?A, #{quota => 1}),
    refused(S, {pipe, ?B, []}, enfile).

a_pipe_past_the_last_number_is_refused_test() ->
    S1 = pipe(?A, #{number_max => 2}),
    {S2, _} = step(S1, {pipe, ?A, []}),
    {S3, _} = step(S2, {closed, ?A, 1, 1}),
    {S4, _} = step(S3, {closed, ?A, 1, 2}),
    refused(S4, {pipe, ?A, []}, enfile).

an_inherited_write_end_is_stored_then_reported_test() ->
    S = pipe(?A),
    {S1, Actions} = step(S, {inherit, ?A, 1, 2, ?B}),
    ?assertEqual([{make_lane, {ring, 1, 2}, {rpage, 1, 2}, 16384},
                  {make_bell, {bell, 1, 3}, ?B, erx_pipe:label(1, 3)},
                  {store_wends, {lock, 1}, 2},
                  {report, ?A, {pipe_writer, 1, 1, 2, {ring, 1, 2}, {rpage, 1, 2}, 16384,
                                {bell, 1, 3}, open}},
                  {reply, {ok, {pipe, write, {1, 3},
                                #{wend => 2, ring => {ring, 1, 2}, rpage => {rpage, 1, 2},
                                  size => 16384, readers => [{0, {bell, 1, 1}}]}}}}],
                 Actions),
    ?assertEqual(2, maps:get(lanes, erx_pipe:view(S1))).

an_inherited_read_end_is_reported_to_every_peer_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 2, ?B}),
    {_, Actions} = step(S1, {inherit, ?A, 1, 1, ?C}),
    ?assertEqual([{make_bell, {bell, 1, 4}, ?C, erx_pipe:label(1, 4)},
                  {report, ?A, {pipe_reader, 1, 2, 1, {bell, 1, 4}, open}},
                  {report, ?B, {pipe_reader, 1, 3, 1, {bell, 1, 4}, open}},
                  {report, ?A, {pipe_reader, 1, 1, 1, {bell, 1, 4}, open}},
                  {reply, {ok, {pipe, read, {1, 4},
                                #{rix => 1, lock => {lock, 1}, wends => 2,
                                  writers => [{1, {ring, 1, 1}, {rpage, 1, 1}, 65536,
                                               {open, {bell, 1, 2}}},
                                              {2, {ring, 1, 2}, {rpage, 1, 2}, 16384,
                                               {open, {bell, 1, 3}}}],
                                  readers => [{0, {bell, 1, 1}}]}}}}],
                 Actions).

an_end_its_requester_does_not_hold_is_refused_test() ->
    S = pipe(?A),
    refused(S, {inherit, ?B, 1, 2, ?C}, ebadf),
    refused(S, {inherit, ?A, 1, 3, ?C}, ebadf),
    refused(S, {inherit, ?A, 2, 1, ?C}, ebadf),
    {S1, _} = step(S, {closed, ?A, 1, 2}),
    refused(S1, {inherit, ?A, 1, 2, ?C}, ebadf).

the_65th_read_end_is_refused_test() ->
    S = lists:foldl(fun(_, Acc) -> element(1, step(Acc, {inherit, ?A, 1, 1, ?B})) end,
                    pipe(?A), lists:seq(1, 63)),
    ?assertEqual(64, map_size(maps:get(readers, maps:get(1, maps:get(pipes, erx_pipe:view(S)))))),
    refused(S, {inherit, ?A, 1, 1, ?B}, emfile).

a_freed_index_is_taken_again_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 1, ?B}),
    {S2, _} = step(S1, {closed, ?A, 1, 1}),
    {_, Actions} = step(S2, {inherit, ?B, 1, 3, ?C}),
    ?assertMatch({ok, {pipe, read, {1, 4}, #{rix := 0}}}, reply(Actions)).

an_inherited_write_end_past_the_quota_is_refused_test() ->
    refused(pipe(?A, #{quota => 1}), {inherit, ?A, 1, 2, ?B}, enfile).

an_end_past_the_last_number_is_refused_test() ->
    {S, _} = step(pipe(?A, #{number_max => 3}), {inherit, ?A, 1, 1, ?B}),
    refused(S, {inherit, ?A, 1, 1, ?B}, enfile),
    refused(S, {inherit, ?A, 1, 2, ?B}, enfile).

a_gone_writer_stays_until_every_reader_drains_it_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 1, ?B}),
    {S2, Gone} = step(S1, {closed, ?A, 1, 2}),
    ?assertEqual([{?A, {pipe_writer_gone, 1, 1, 1}}, {?B, {pipe_writer_gone, 1, 3, 1}}],
                 reports(Gone)),
    %% The server keeps the gone writer's doorbell until it forgets the writer.
    ?assertEqual([], closes(Gone)),
    ?assertEqual(1, maps:get(lanes, erx_pipe:view(S2))),
    {S3, First} = step(S2, {drained, ?A, 1, 1, 1}),
    ?assertEqual([], First),
    unchanged(S3, {drained, ?A, 1, 1, 1}),
    {S4, Last} = step(S3, {drained, ?B, 1, 3, 1}),
    ?assertEqual([{close, {ring, 1, 1}}, {close, {rpage, 1, 1}}, {close, {bell, 1, 2}}], Last),
    ?assertEqual(0, maps:get(lanes, erx_pipe:view(S4))).

a_writer_gone_with_no_reader_is_forgotten_at_once_test() ->
    {S1, _} = step(pipe(?A), {closed, ?A, 1, 1}),
    {S2, Actions} = step(S1, {closed, ?A, 1, 2}),
    ?assertEqual([{close, {ring, 1, 1}}, {close, {rpage, 1, 1}}, {close, {bell, 1, 2}},
                  {close, {lock, 1}}], Actions),
    ?assertEqual(#{lanes => 0, next_pipe => 2, pipes => #{}}, erx_pipe:view(S2)).

a_gone_reader_frees_the_lock_and_is_reported_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 2, ?B}),
    {_, Actions} = step(S1, {closed, ?A, 1, 1}),
    ?assertEqual([{free_lock, {lock, 1}, 0},
                  {close, {bell, 1, 1}},
                  {report, ?A, {pipe_reader_gone, 1, 2, 0}},
                  {report, ?B, {pipe_reader_gone, 1, 3, 0}}], Actions).

a_gone_reader_is_no_longer_waited_for_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 1, ?B}),
    {S2, _} = step(S1, {closed, ?A, 1, 2}),
    {S3, Actions} = step(S2, {gone, ?B}),
    ?assertEqual([{free_lock, {lock, 1}, 1},
                  {close, {bell, 1, 3}},
                  {report, ?A, {pipe_reader_gone, 1, 1, 1}}], Actions),
    {_, Last} = step(S3, {drained, ?A, 1, 1, 1}),
    ?assertEqual([{close, {ring, 1, 1}}, {close, {rpage, 1, 1}}, {close, {bell, 1, 2}}], Last).

a_new_reader_drains_a_gone_writer_too_test() ->
    {S1, _} = step(pipe(?A), {closed, ?A, 1, 2}),
    {S2, Actions} = step(S1, {inherit, ?A, 1, 1, ?B}),
    {ok, Descriptor} = reply(Actions),
    ?assertMatch({pipe, read, {1, 3},
                  #{wends := 1, writers := [{1, {ring, 1, 1}, {rpage, 1, 1}, 65536, gone}]}},
                 Descriptor),
    %% The server still holds the gone writer's doorbell, but no copy names it.
    ?assertNot(lists:keymember({bell, 1, 2}, 1, erx_pipe:copies(Descriptor))),
    ?assertEqual([{?A, {pipe_reader, 1, 1, 1, {bell, 1, 3}, open}}], reports(Actions)),
    {S3, []} = step(S2, {drained, ?A, 1, 1, 1}),
    {_, Last} = step(S3, {drained, ?B, 1, 3, 1}),
    ?assertEqual([{ring, 1, 1}, {rpage, 1, 1}, {bell, 1, 2}], closes(Last)).

a_gone_writer_counts_against_the_quota_test() ->
    {S1, _} = step(pipe(?A, #{quota => 1}), {closed, ?A, 1, 2}),
    refused(S1, {pipe, ?A, []}, enfile),
    {S2, _} = step(S1, {drained, ?A, 1, 1, 1}),
    {_, Actions} = step(S2, {pipe, ?A, []}),
    ?assertMatch({ok, _, _}, reply(Actions)).

a_holder_gone_takes_every_end_it_held_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 1, ?B}),
    {S2, _} = step(S1, {pipe, ?A, []}),
    {S3, Actions} = step(S2, {gone, ?A}),
    %% ?B alone is told; ?A is gone.
    ?assertEqual([{?B, {pipe_reader_gone, 1, 3, 0}}, {?B, {pipe_writer_gone, 1, 3, 1}}],
                 reports(Actions)),
    %% ?A's write end of pipe 1 is gone but kept for ?B, with its doorbell.
    ?assertEqual([{bell, 1, 1}, {bell, 2, 1}, {ring, 2, 1}, {rpage, 2, 1}, {bell, 2, 2},
                  {lock, 2}], closes(Actions)),
    ?assertEqual(#{lanes => 1, next_pipe => 3,
                   pipes => #{1 => #{wends => 1, next_end => 4,
                                     writers => #{1 => #{end_id => 2, holder => ?A,
                                                         size => 65536, state => {gone, [1]}}},
                                     readers => #{1 => #{end_id => 3, holder => ?B}}}}},
                 erx_pipe:view(S3)),
    unchanged(S3, {gone, ?A}).

a_notice_from_another_holder_is_ignored_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 1, ?B}),
    {S2, _} = step(S1, {closed, ?A, 1, 2}),
    unchanged(S2, {closed, ?B, 1, 1}),
    unchanged(S2, {closed, ?C, 1, 3}),
    unchanged(S2, {closed, ?A, 1, 2}),
    unchanged(S2, {closed, ?A, 9, 1}),
    unchanged(S2, {drained, ?C, 1, 1, 1}),
    unchanged(S2, {drained, ?B, 1, 1, 1}),
    unchanged(S2, {drained, ?A, 1, 3, 1}),
    unchanged(S2, {drained, ?A, 1, 1, 2}),
    unchanged(S2, {drained, ?A, 1, 2, 1}),
    unchanged(S2, {install_failed, ?B, 1, 1}),
    unchanged(S2, {gone, ?C}).

a_drained_notice_for_an_open_writer_is_ignored_test() ->
    unchanged(pipe(?A), {drained, ?A, 1, 1, 1}).

a_failed_install_loses_that_end_alone_test() ->
    {S1, _} = step(pipe(?A), {inherit, ?A, 1, 2, ?B}),
    {S2, Actions} = step(S1, {install_failed, ?A, 1, 1}),
    ?assertEqual([{report, ?A, {pipe_lost, 1, 1}}], Actions),
    ?assertEqual(S1, S2).

a_label_names_its_pipe_and_end_test() ->
    Label = erx_pipe:label(1, 1),
    ?assert(Label >= 1 bsl 32),
    ?assertNotEqual(?ERX_PROG_CHANNEL_LABEL, Label),
    ?assertEqual({1, 1}, erx_pipe:label_end(Label)),
    Max = 16#ffffffff,
    ?assertEqual({Max, Max}, erx_pipe:label_end(erx_pipe:label(Max, Max))),
    ?assertEqual(16#ffffffffffffffff, erx_pipe:label(Max, Max)),
    ?assertError(function_clause, erx_pipe:label(0, 1)),
    ?assertError(function_clause, erx_pipe:label(1, Max + 1)),
    ?assertError(function_clause, erx_pipe:label_end(1)),
    ?assertError(function_clause, erx_pipe:label_end(1 bsl 32)).

%% docs/design-pipes.md, "Hand-offs", the rights of a copy: liberx maps
%% every memory copy, and erx_vm_map needs MAP on the memory object.
copies_carry_the_rights_their_end_needs_test() ->
    R = ?ERX_HR_READ bor ?ERX_HR_MAP,
    RW = ?ERX_HR_READ bor ?ERX_HR_WRITE bor ?ERX_HR_MAP,
    T = ?ERX_HR_TRIGGER,
    {S, Actions} = step(erx_pipe:new(#{}), {pipe, ?A, []}),
    {ok, Read, Write} = reply(Actions),
    ?assertEqual([{{lock, 1}, RW}, {{ring, 1, 1}, R}, {{rpage, 1, 1}, RW}, {{bell, 1, 2}, T}],
                 erx_pipe:copies(Read)),
    ?assertEqual([{{ring, 1, 1}, RW}, {{rpage, 1, 1}, R}, {{bell, 1, 1}, T}],
                 erx_pipe:copies(Write)),
    {S1, Joined} = step(S, {inherit, ?A, 1, 2, ?B}),
    [{?A, Writer}] = reports(Joined),
    ?assertEqual([{{ring, 1, 2}, R}, {{rpage, 1, 2}, RW}, {{bell, 1, 3}, T}],
                 erx_pipe:copies(Writer)),
    {_, Reader} = step(S1, {inherit, ?A, 1, 1, ?C}),
    [{?A, ToWriter} | _] = reports(Reader),
    ?assertEqual([{{bell, 1, 4}, T}], erx_pipe:copies(ToWriter)),
    ?assertEqual([], erx_pipe:copies({pipe_writer_gone, 1, 1, 1})),
?assertEqual([], erx_pipe:copies({pipe_lost, 1, 1})),
Copies = lists:append([erx_pipe:copies(D) || D <- [Read, Write, Writer, ToWriter]]),
[?assertEqual(?ERX_HR_MAP, Rights band ?ERX_HR_MAP) || {{Kind, _, _}, Rights} <- Copies, Kind =/= bell],
[?assertEqual(?ERX_HR_MAP, Rights band ?ERX_HR_MAP) || {{lock, _}, Rights} <- Copies],
[?assertEqual(0, Rights band (?ERX_HR_DUP bor ?ERX_HR_GIVE bor ?ERX_HR_DESTROY)) || {_, Rights} <- Copies].

options_are_checked_test() ->
    ?assertError(badarg, erx_pipe:new(#{quota => 0})),
    %% The program port sizes a program's credit for at most pipes_quota lanes.
    ?assertError(badarg, erx_pipe:new(#{quota => ?ERX_PIPES_QUOTA + 1})),
    ?assertError(badarg, erx_pipe:new(#{number_max => 1})),
    ?assertError(badarg, erx_pipe:new(#{number_max => 1 bsl 32})),
    ?assertError(badarg, erx_pipe:new(#{readers_max => 65})),
    ?assertError(badarg, erx_pipe:new(#{other => 1})).

first_pipe_continues_a_predecessors_numbering_test() ->
    {_, Actions} = step(erx_pipe:new(#{first_pipe => 5}), {pipe, ?A, []}),
    ?assertMatch({ok, {pipe, read, {5, 1}, _}, {pipe, write, {5, 2}, _}}, reply(Actions)),
    %% Past the last number every pipe is refused.
    refused(erx_pipe:new(#{number_max => 4, first_pipe => 5}), {pipe, ?A, []}, enfile),
    ?assertError(badarg, erx_pipe:new(#{first_pipe => 0})),
    ?assertError(badarg, erx_pipe:new(#{number_max => 4, first_pipe => 6})).

%% docs/design-pipes.md, Verification, program holders: a program holding
%% two write ends of one pipe keeps one across exec, and its reader is
%% told the other is gone and never counts zero write ends.
exec_keeps_an_end_and_closes_the_others_test() ->
    S0 = pipe(?B),
    {S1, _} = step(S0, {inherit, ?B, 1, 2, ?A}),
    {S2, _} = step(S1, {inherit, ?A, 1, 3, ?A}),
    {S3, _} = step(S2, {closed, ?B, 1, 2}),
    {S4, Actions} = step(S3, {exec, ?A, [{fd1, 1, 3}]}),
    %% The reply comes first, from the records before the closes.
    ?assertMatch([{reply, {ok, [{fd1, {pipe, write, {1, 3}, #{wend := 2}}}]}} | _], Actions),
    ?assertEqual([{?B, {pipe_writer_gone, 1, 1, 3}}], reports(Actions)),
    #{pipes := #{1 := #{writers := Writers}}} = erx_pipe:view(S4),
    ?assertEqual([{2, ?A}], [{W, H} || W := #{holder := H, state := open} <- Writers]).

exec_of_an_end_not_held_is_refused_test() ->
    S = pipe(?A),
    refused(S, {exec, ?A, [{fd0, 1, 3}]}, ebadf),
    refused(S, {exec, ?A, [{fd0, 1, 1}, {fd1, 1, 1}]}, ebadf),
    refused(S, {exec, ?A, [{fd0, 1, 1}, {fd1, 1}]}, badarg),
    refused(S, {exec, ?A, [{fd0, 1, 1}, {fd0, 1, 2}]}, badarg),
    refused(S, {exec, ?A, [{fd0, 1, 1} | {fd1, 1, 2}]}, badarg),
    refused(S, {exec, ?A, [{Fd, 1, 1} || Fd <- lists:seq(0, ?ERX_PROG_FDS_MAX)]}, badarg),
    {S1, Actions} = step(S, {exec, ?A, []}),
    ?assertEqual({ok, []}, reply(Actions)),
    ?assertEqual(#{}, maps:get(pipes, erx_pipe:view(S1))).
