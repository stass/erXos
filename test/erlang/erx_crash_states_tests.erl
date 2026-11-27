%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the crash-state generator, the model's FAT rule, the obligations
%% of a state's moments and the failure records (docs/design-crash-states.md,
%% "Tests"), over synthetic traces on a small base image. ERX_CRASH_OUT: the
%% directory the host test prepared for this run's records, holding `unit`.

-module(erx_crash_states_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).
-define(BASE, <<0:(16 * ?SECTOR * 8)>>).

s(N) -> binary:copy(<<N>>, ?SECTOR).
w(Lba, N) -> {write, Lba, s(N), ok}.

only_epoch(Trace) ->
    [Epoch] = erx_crash_states:epochs(Trace, ?BASE),
    Epoch.

states(Epoch) -> erx_crash_states:states(Epoch, #{mode => atomic, bound => 4096, seed => 1}).

%% Each state's image, as the sectors 0..15 its read function answers.
images(Epoch, #{states := States}) ->
    lists:usort([image_of(Epoch, Choice) || #{choice := Choice} <- States]).

image_of(Epoch, Choice) ->
    Read = erx_crash_states:read_fun(?BASE, Epoch, Choice),
    [element(2, Read(Lba)) || Lba <- lists:seq(0, 15)].

%% ---------------------------------------------------------------------------
%% Counts and epochs
%% ---------------------------------------------------------------------------

state_counts_test() ->
    Three = only_epoch([w(1, 1), w(2, 2), w(3, 3)]),
    #{count := 8, coverage := exhaustive, states := ThreeStates} = states(Three),
    ?assertEqual(8, length(images(Three, states(Three)))),
    ?assertEqual(8, length(ThreeStates)),
    Six = only_epoch([w(1, 1), w(1, 2), w(2, 3)]),
    ?assertMatch(#{count := 6}, states(Six)),
    ?assertEqual(6, length(images(Six, states(Six)))),
    Durable = only_epoch([w(1, 1), w(1, 0)]),
    ?assertMatch(#{count := 2}, states(Durable)).

%% A flush answered ok ends an epoch; a failed one ends nothing, so a state with a
%% later write landed and an earlier one lost is generated.
epochs_test() ->
    Trace = [w(1, 1), {flush, {error, eio}}, w(2, 2), {flush, ok}],
    Epochs = erx_crash_states:epochs(Trace, ?BASE),
    ?assertEqual(2, length(Epochs)),
    Lost = [s(0), s(0), s(2) | lists:duplicate(13, s(0))],
    ?assert(lists:any(fun(E) -> lists:member(Lost, images(E, states(E))) end, Epochs)),
    [_, Last] = Epochs,
    ?assertMatch(#{count := 1}, states(Last)).

%% Over every prefix of random epochs (a sample of 200 epochs from a fixed seed, not
%% every epoch), each state a crash at that moment leaves is among the epoch end's.
earlier_states_are_among_the_end_states_test() ->
    lists:foldl(fun(_, R) ->
                        {Length, R1} = rand:uniform_s(6, R),
                        {Writes, R2} = lists:mapfoldl(fun(_, Acc) ->
                                                              {Lba, A1} = rand:uniform_s(4, Acc),
                                                              {Value, A2} = rand:uniform_s(3, A1),
                                                              {w(Lba - 1, Value - 1), A2}
                                                      end, R1, lists:seq(1, Length)),
                        Full = only_epoch(Writes),
                        End = images(Full, states(Full)),
                        [?assertEqual([], images(P, states(P)) -- End)
                         || J <- lists:seq(0, Length), P <- [only_epoch(lists:sublist(Writes, J))]],
                        R2
                end, rand:seed_s(exsss, {1, 2, 3}), lists:seq(1, 200)).

%% Past the bound: the in-order cuts and the one-left-durable states whole, the
%% rest drawn from the seed, reported as a sample with its seed and version.
a_sampled_epoch_says_so_test() ->
    Epoch = only_epoch([w(Lba, 1) || Lba <- lists:seq(0, 12)]),
    Options = #{mode => atomic, bound => 100, seed => 7},
    #{count := 8192, coverage := Coverage, states := States} = erx_crash_states:states(Epoch, Options),
    Version = erx_crash_states:version(),
    ?assertEqual({sampled, 100, 8192, 7, Version}, Coverage),
    Choices = [C || #{choice := C} <- States],
    ?assertEqual(100, length(lists:usort(Choices))),
    Cuts = [maps:from_list([{Lba, 1} || Lba <- lists:seq(0, J - 1)]) || J <- lists:seq(0, 13)],
    Lefts = [maps:remove(Lba, maps:from_list([{L, 1} || L <- lists:seq(0, 12)])) || Lba <- lists:seq(0, 12)],
    ?assertEqual([], lists:usort(Cuts ++ Lefts) -- Choices),
    ?assertEqual(States, maps:get(states, erx_crash_states:states(Epoch, Options))),
    ?assertNotEqual(States, maps:get(states, erx_crash_states:states(Epoch, Options#{seed := 8}))),
    ?assertEqual({error, {unsupported_mode, torn}}, erx_crash_states:states(Epoch, Options#{mode := torn})).

%% A state's earliest moment is its latest chosen write's position.
earliest_moment_test() ->
    Epoch = only_epoch([w(1, 1), w(2, 2), w(1, 3)]),
    #{states := States} = states(Epoch),
    Moments = maps:from_list([{C, T} || #{choice := C, t := T} <- States]),
    ?assertEqual(0, maps:get(#{}, Moments)),
    ?assertEqual(2, maps:get(#{2 => 1}, Moments)),
    ?assertEqual(3, maps:get(#{1 => 2}, Moments)),
    ?assertEqual(2, maps:get(#{1 => 1, 2 => 1}, Moments)).

%% ---------------------------------------------------------------------------
%% The model and the moments
%% ---------------------------------------------------------------------------

fat_rule_test() ->
    A = binary:copy(<<"a">>, 1024),
    B = binary:copy(<<"b">>, 1024),
    Acked = #{[] => dir, [<<"f">>] => {file, A}},
    Overwrite = obligation_after(Acked, [{write, [<<"f">>], 0, B}]),
    Mixed = <<(binary:part(B, 0, 512))/binary, (binary:part(A, 512, 512))/binary>>,
    ?assertEqual(ok, erx_fs_model:judge(Overwrite, #{[] => dir, [<<"f">>] => {file, Mixed}})),
    Foreign = <<(binary:part(B, 0, 512))/binary, (binary:copy(<<"c">>, 512))/binary>>,
    ?assertMatch({error, {[<<"f">>], {block_in_no_entry, 1}}},
                 erx_fs_model:judge(Overwrite, #{[] => dir, [<<"f">>] => {file, Foreign}})),
    ?assertMatch({error, {[<<"f">>], {size_in_no_entry, 1536}}},
                 erx_fs_model:judge(Overwrite, #{[] => dir, [<<"f">>] => {file, <<B/binary, 0:4096>>}})),
    ?assertMatch({error, {[<<"f">>], missing}}, erx_fs_model:judge(Overwrite, #{[] => dir})),
    ?assertMatch({error, {[<<"f">>], {not_as_acknowledged, _, _}}},
                 erx_fs_model:judge(erx_fs_model:obligation(erx_fs_model:new(Acked)), #{[] => dir, [<<"f">>] => {file, B}})),
    ?assertEqual(ok, erx_fs_model:judge(obligation_after(Acked, [{rename, [<<"f">>], [<<"g">>]}]), #{[] => dir})),
    Created1 = obligation_after(Acked, [{create, [<<"A New Long Name.txt">>]}]),
    ?assertEqual(ok, erx_fs_model:judge(Created1, #{[] => dir, [<<"f">>] => {file, A}, [<<"ANEWLO~1.TXT">>] => {file, <<>>}})),
    ?assertMatch({error, {[<<"STRAY.TXT">>], unpromised_name}},
                 erx_fs_model:judge(Created1, #{[] => dir, [<<"f">>] => {file, A}, [<<"STRAY.TXT">>] => {file, <<>>}})).

%% A stray write to a committed file that only a later operation's bytes would excuse
%% fails at its earliest moment, before that operation began.
a_stray_write_fails_at_its_earliest_moment_test() ->
    F = [<<"f">>],
    Acked = #{[] => dir, F => {file, <<"old">>}},
    Obligations = [{0, erx_fs_model:obligation(erx_fs_model:new(Acked))},
                   {5, obligation_after(Acked, [{write, F, 0, <<"new">>}])}],
    Stray = #{[] => dir, F => {file, <<"new">>}},
    ?assertMatch({error, {0, {F, {not_as_acknowledged, _, _}}}},
                 erx_crash_run:judged(erx_crash_run:moments(3, 10, Obligations), Stray)),
    ?assertEqual(ok, erx_crash_run:judged(erx_crash_run:moments(6, 10, Obligations), Stray)).

%% ---------------------------------------------------------------------------
%% Failure records
%% ---------------------------------------------------------------------------

out() ->
    Out = filename:join(os:getenv("ERX_CRASH_OUT"), "unit"),
    true = filelib:is_dir(Out),
    Out.

a_failing_state_replays_byte_for_byte_test() ->
    Trace = [w(1, 1), w(2, 2), {flush, ok}, w(1, 3), w(3, 4)],
    Out = out(),
    Failure = #{base => ?BASE, trace => Trace, epoch => 2, choice => #{3 => 1}, step => obligations,
                image_index => 1, workload => synthetic},
    Record = erx_crash_run:write_failure(Out, Failure, 1),
    {ok, Image} = file:read_file(filename:rootname(Record) ++ ".img"),
    ?assertEqual(iolist_to_binary([s(0), s(1), s(2), s(4) | lists:duplicate(12, s(0))]), Image),
    ?assertEqual(ok, erx_crash_run:replay(Record, Out)),
    %% A record from another version of the generator is refused, naming both.
    {ok, Bytes} = file:read_file(Record),
    Other = filename:join(Out, "failure-9-1.term"),
    ok = file:write_file(Other, term_to_binary((binary_to_term(Bytes))#{version := <<"0">>})),
    ok = file:write_file(filename:join(Out, "failure-9-1.img"), Image),
    Ours = erx_crash_states:version(),
    ?assertEqual({error, {version, <<"0">>, Ours}}, erx_crash_run:replay(Other, Out)),
    %% A base that does not match the record's hash is refused, naming both.
    Sha = binary:encode_hex(crypto:hash(sha256, ?BASE), lowercase),
    BasePath = filename:join(Out, <<"base-", Sha/binary, ".img">>),
    ok = file:write_file(BasePath, <<1, (binary:part(?BASE, 1, byte_size(?BASE) - 1))/binary>>),
    ?assertMatch({error, {base_sha256, Sha, _}}, erx_crash_run:replay(Record, Out)),
    ok = file:write_file(BasePath, ?BASE).

%% A file cut short and written again in one batch may keep its old size over its new
%% block: bytes past the new size that the file held before are bytes written to it.
a_cut_batch_keeps_bytes_past_a_new_size_test() ->
    X = [<<"x">>],
    Acked = #{[] => dir, X => {file, <<"deep\n">>}},
    Obligation = obligation_after(Acked, [{truncate, X, 2}, {write, X, 0, <<"X">>}]),
    ?assertEqual(ok, erx_fs_model:judge(Obligation, Acked#{X := {file, <<"Xeep\n">>}})),
    %% Zeros the file never held there are no bytes written to it.
    ?assertMatch({error, {X, {block_in_no_entry, 0}}}, erx_fs_model:judge(Obligation, Acked#{X := {file, <<"Xe", 0, 0, 0>>}})),
    ?assertMatch({error, {X, {block_in_no_entry, 0}}}, erx_fs_model:judge(Obligation, Acked#{X := {file, <<"Xeqp\n">>}})).

%% A file renamed and then written in one batch may stand under its old name with the
%% new bytes: its bytes follow the file, not the name.
a_renamed_file_keeps_its_bytes_under_its_old_name_test() ->
    A = binary:copy(<<"a">>, 1024),
    Acked = #{[] => dir, [<<"f">>] => {file, A}},
    Obligation = obligation_after(Acked, [{rename, [<<"f">>], [<<"g">>]}, {write, [<<"g">>], 512, binary:copy(<<"b">>, 512)}]),
    New = <<(binary:part(A, 0, 512))/binary, (binary:copy(<<"b">>, 512))/binary>>,
    ?assertEqual(ok, erx_fs_model:judge(Obligation, #{[] => dir, [<<"f">>] => {file, New}})),
    ?assertMatch({error, {[<<"f">>], {block_in_no_entry, 1}}},
                 erx_fs_model:judge(Obligation, #{[] => dir, [<<"f">>] => {file, <<A:512/binary, (binary:copy(<<"c">>, 512))/binary>>}})).

%% The obligation once every one of Ops has begun, none acknowledged.
obligation_after(Acked, Ops) ->
    erx_fs_model:obligation(lists:foldl(fun(I, M) -> erx_fs_model:follow({'begin', I}, Ops, M) end,
                                        erx_fs_model:new(Acked), lists:seq(1, length(Ops)))).
