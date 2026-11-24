%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The development passphrase checker (docs/design-login.md, "The passphrase check")
%% and root's passphrase line (docs/design-ssh.md, "Root's passphrase on the medium"):
%% erx_passphrase_hash against FreeBSD 14.3.0's crypt-sha256.c test vectors,
%% erx_boot_passphrase's refusals, erx_passphrase_limits and erx_passphrase_check.
%% test/host/erx_passphrase_test.rb runs it on stock's emulator, with erx_bytes'
%% host stand-in, and against each seeded fault.
-module(erx_passphrase_tests).
-include_lib("eunit/include/eunit.hrl").

%% crypt-sha256.c's tests2[]: the salt field as written, the key, the line.
vectors() ->
    [{<<"$5$saltstring">>, <<"Hello world!">>,
      <<"$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5">>},
     {<<"$5$rounds=10000$saltstringsaltstring">>, <<"Hello world!">>,
      <<"$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA">>},
     {<<"$5$rounds=5000$toolongsaltstring">>, <<"This is just a test">>,
      <<"$5$rounds=5000$toolongsaltstrin$Un/5jzAHMgOGZ5.mWJpuVolil07guHPvOW8mGRcvxa5">>},
     {<<"$5$rounds=1400$anotherlongsaltstring">>,
      <<"a very much longer text to encrypt.  This one even stretches over morethan one line.">>,
      <<"$5$rounds=1400$anotherlongsalts$Rx.j8H.h8HjEDGomFU8bDkXm3XIUnzyxf12oP84Bnq1">>},
     {<<"$5$rounds=77777$short">>, <<"we have a short salt string but not a short password">>,
      <<"$5$rounds=77777$short$JiO1O3ZpDAxGJeaDIuqCoEFysAe1mZNJRs3pw0KQRd/">>},
     {<<"$5$rounds=10$roundstoolow">>, <<"the minimum number is still observed">>,
      <<"$5$rounds=1000$roundstoolow$yfvwcWrQ8l/K0DAWyuPMDNHpIVlTQebY9l/gL972bIC">>}].

record(Line) ->
    {ok, Bytes} = erx_boot_passphrase:decode(Line),
    {ok, Record} = erx_passphrase_hash:decode(Bytes),
    Record.

hello() -> record(<<"$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5\n">>).

%% ---------------------------------------------------------------------------
%% The derivation and the line
%% ---------------------------------------------------------------------------

freebsd_s_vectors_match_test() ->
    [?assert(erx_passphrase_hash:matches(Key, record(Line))) || {_Salt, Key, Line} <- vectors()],
    [?assertNot(erx_passphrase_hash:matches(<<Key/binary, "x">>, record(Line))) || {_Salt, Key, Line} <- vectors()].

a_hash_differing_in_its_last_byte_does_not_match_test() ->
    #{hash := <<Head:31/binary, Last>>} = Record = hello(),
    ?assert(erx_passphrase_hash:matches(<<"Hello world!">>, Record)),
    ?assertNot(erx_passphrase_hash:matches(<<"Hello world!">>, Record#{hash := <<Head/binary, (Last bxor 1)>>})).

a_line_decodes_to_its_rounds_and_salt_test() ->
    ?assertMatch(#{rounds := 5000, salt := <<"saltstring">>}, hello()),
    ?assertMatch(#{rounds := 77777, salt := <<"short">>},
                 record(<<"$5$rounds=77777$short$JiO1O3ZpDAxGJeaDIuqCoEFysAe1mZNJRs3pw0KQRd/\r\n">>)).

malformed_lines_are_refused_test() ->
    Hash = <<"5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5">>,
    Refused = [<<>>, <<"\n">>,
               <<"$6$saltstring$", Hash/binary>>,
               <<"$5$saltstring$", (binary:part(Hash, 0, 42))/binary>>,
               <<"$5$saltstring$", Hash/binary, "x">>,
               <<"$5$saltstring$", Hash/binary, "\n\n">>,
               <<"$5$saltstring$", Hash/binary, "\r">>,
               <<"$5$$", Hash/binary>>,
               <<"$5$salt string$", Hash/binary>>,
               <<"$5$saltstringsaltstr$", Hash/binary>>,
               <<"$5$rounds=999$saltstring$", Hash/binary>>,
               <<"$5$rounds=100001$saltstring$", Hash/binary>>,
               <<"$5$rounds=05000$saltstring$", Hash/binary>>,
               <<"$5$rounds=5x00$saltstring$", Hash/binary>>,
               <<"$5$saltstring$", (binary:part(Hash, 0, 42))/binary, "!">>],
    [?assertEqual({error, not_a_crypt_string}, erx_boot_passphrase:decode(Line)) || Line <- Refused].

a_hash_with_spare_bits_set_is_refused_test() ->
    %% The last character spells 18 bits whose top two are zero; `5` is 7 and `w`
    %% is 60, whose top bits are set, so the same bytes would have two spellings.
    Hash = <<"5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEcw">>,
    ?assertEqual({error, not_a_crypt_string}, erx_boot_passphrase:decode(<<"$5$saltstring$", Hash/binary>>)).

a_long_file_is_refused_test() ->
    ?assertEqual({error, too_long}, erx_boot_passphrase:decode(binary:copy(<<"$">>, 129))).

a_record_from_another_domain_is_checked_test() ->
    {ok, Good} = erx_boot_passphrase:decode(<<"$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5">>),
    <<Rounds:32, Hash:32/binary, Salt/binary>> = Good,
    Bad = [<<>>, binary:part(Good, 0, 36), <<Good/binary, (binary:copy(<<"a">>, 7))/binary>>,
           <<999:32, Hash/binary, Salt/binary>>, <<100001:32, Hash/binary, Salt/binary>>,
           <<Rounds:32, Hash/binary, "$", Salt/binary>>],
    [?assertEqual({error, malformed}, erx_passphrase_hash:decode(B)) || B <- Bad].

%% ---------------------------------------------------------------------------
%% The limits
%% ---------------------------------------------------------------------------

five_failures_limit_a_name_for_a_minute_test() ->
    Counts = lists:foldl(fun(T, C) -> erx_passphrase_limits:failed(<<"root">>, {peer, T}, T, C) end,
                         erx_passphrase_limits:new(), lists:seq(1, 5)),
    ?assertEqual(limited, erx_passphrase_limits:admit(<<"root">>, other, 10, Counts)),
    ?assertEqual(ok, erx_passphrase_limits:admit(<<"other">>, other, 10, Counts)),
    ?assertEqual(ok, erx_passphrase_limits:admit(<<"root">>, other, 60005, Counts)).

five_failures_limit_a_terminal_test() ->
    Counts = lists:foldl(fun(N, C) -> erx_passphrase_limits:failed(integer_to_binary(N), peer, N, C) end,
                         erx_passphrase_limits:new(), lists:seq(1, 5)),
    ?assertEqual(limited, erx_passphrase_limits:admit(<<"new">>, peer, 10, Counts)),
    ?assertEqual(ok, erx_passphrase_limits:admit(<<"new">>, elsewhere, 10, Counts)).

old_counters_are_dropped_test() ->
    Old = erx_passphrase_limits:failed(<<"a">>, a, 0, erx_passphrase_limits:new()),
    ?assertEqual(2, erx_passphrase_limits:size(Old)),
    ?assertEqual(2, erx_passphrase_limits:size(erx_passphrase_limits:failed(<<"b">>, b, 60000, Old))).

%% ---------------------------------------------------------------------------
%% The checker
%% ---------------------------------------------------------------------------

%% Starts the checker on a record read by Read, counting each read, at a clock the
%% case sets; stops any earlier one.
checker(Development, Read) ->
    checker(Development, Read, 30000).

checker(Development, Read, Deadline) ->
    Case = self(),
    case whereis(erx_passphrase_check) of
        undefined -> ok;
        Old -> stop(Old)
    end,
    {ok, Pid} = erx_passphrase_check:start_link(
                  #{development => Development,
                    read => fun() -> Case ! read, Read() end,
                    now => fun() -> 0 end,
                    worker_ms => Deadline}),
    unlink(Pid),
    _ = reads(),
    Pid.

hello_record() ->
    {ok, Bytes} = erx_boot_passphrase:decode(<<"$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5">>),
    fun() -> {ok, Bytes} end.

reads() -> receive read -> 1 + reads() after 0 -> 0 end.

%% Kills a checker and waits for its end, so its name is free.
stop(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, _, _} -> ok end.

check(Name, Passphrase) -> erx_passphrase_check:check(network, Name, Passphrase, {peer, 1}).

root_s_passphrase_matches_test() ->
    checker(true, hello_record()),
    ?assertEqual(match, check(<<"root">>, <<"Hello world!">>)),
    ?assertEqual(no_match, check(<<"root">>, <<"Hello world">>)).

a_stranger_with_root_s_passphrase_is_no_match_test() ->
    checker(true, hello_record()),
    ?assertEqual(no_match, check(<<"toor">>, <<"Hello world!">>)),
    ?assertEqual(no_match, check(<<"nobody">>, <<"wrong">>)),
    %% A stranger is read and derived for as root is.
    ?assertEqual(2, reads()).

five_failures_limit_the_name_test() ->
    checker(true, hello_record()),
    [?assertEqual(no_match, check(<<"root">>, <<"wrong">>)) || _ <- lists:seq(1, 5)],
    _ = reads(),
    ?assertEqual(limited, check(<<"root">>, <<"Hello world!">>)),
    ?assertEqual(0, reads()),
    ?assertEqual(limited, erx_passphrase_check:check(network, <<"other">>, <<"x">>, {peer, 1})).

a_release_build_reads_nothing_test() ->
    checker(false, hello_record()),
    ?assertEqual(unavailable, check(<<"root">>, <<"Hello world!">>)),
    ?assertEqual(0, reads()).

no_record_is_unavailable_for_every_name_test() ->
    checker(true, fun() -> {ok, <<>>} end),
    ?assertEqual(unavailable, check(<<"root">>, <<"Hello world!">>)),
    ?assertEqual(unavailable, check(<<"nobody">>, <<"Hello world!">>)),
checker(true, fun() -> {ok, <<"not a record">>} end),
?assertEqual(unavailable, check(<<"nobody">>, <<"Hello world!">>)),
    checker(true, fun() -> {error, eio} end),
    ?assertEqual(unavailable, check(<<"root">>, <<"Hello world!">>)),
    checker(true, hello_record()),
    ?assertEqual(match, check(<<"root">>, <<"Hello world!">>)).

a_reader_that_raises_is_unavailable_test() ->
    checker(true, fun() -> error(boom) end),
    ?assertEqual(unavailable, check(<<"root">>, <<"Hello world!">>)).

bad_arguments_are_badarg_test() ->
    checker(true, hello_record()),
    ?assertEqual(badarg, check(<<>>, <<"x">>)),
    ?assertEqual(badarg, check(<<"root">>, <<>>)),
    ?assertEqual(badarg, check(<<"root">>, binary:copy(<<"a">>, 257))),
    ?assertEqual(badarg, check(root, <<"x">>)),
    ?assertEqual(0, reads()).

checks_wait_for_one_derivation_at_a_time_test() ->
    Case = self(),
    Gate = fun() -> Case ! {reading, self()}, receive go -> ok end, (hello_record())() end,
    checker(true, Gate),
    Callers = [spawn_link(fun() -> Case ! {answer, check(<<"root">>, <<"Hello world!">>)} end) || _ <- [1, 2]],
    First = receive {reading, W1} -> W1 after 5000 -> none end,
    %% The second check waits in the queue: no second read starts while the first runs.
    ?assertEqual(none, receive {reading, _} -> second after 200 -> none end),
    First ! go,
    Second = receive {reading, W2} -> W2 after 5000 -> none end,
    Second ! go,
    ?assertEqual([match, match], [receive {answer, A} -> A after 5000 -> timeout end || _ <- Callers]).

no_status_shows_a_request_test() ->
    Case = self(),
    checker(true, fun() -> Case ! {reading, self()}, receive go -> (hello_record())() end end),
    spawn(fun() -> check(<<"first-name">>, <<"first-passphrase">>) end),
    Worker = receive {reading, W} -> W after 5000 -> none end,
    spawn(fun() -> check(<<"queued-name">>, <<"queued-passphrase">>) end),
    timer:sleep(50),
    Status = term_to_binary(sys:get_status(erx_passphrase_check)),
    [?assertEqual(nomatch, binary:match(Status, Secret))
     || Secret <- [<<"first-passphrase">>, <<"queued-passphrase">>, <<"first-name">>, <<"queued-name">>]],
    Worker ! go.

a_check_with_no_checker_is_unavailable_test() ->
    case whereis(erx_passphrase_check) of
        undefined -> ok;
        Old -> stop(Old)
    end,
    ?assertEqual(unavailable, check(<<"root">>, <<"Hello world!">>)).

the_first_check_waits_out_the_tree_s_eagain_test() ->
    Case = self(),
    Counter = spawn_link(fun() -> eagain_twice(2) end),
    checker(true, fun() -> Counter ! {next, self()}, receive {Counter, Answer} -> Answer end end),
    ?assertEqual(match, check(<<"root">>, <<"Hello world!">>)),
    Case ! done.

eagain_twice(0) ->
    receive {next, From} -> From ! {self(), (hello_record())()}, eagain_twice(0) end;
eagain_twice(N) ->
    receive {next, From} -> From ! {self(), {error, eagain}}, eagain_twice(N - 1) end.

a_worker_past_its_deadline_is_unavailable_and_not_counted_test() ->
    checker(true, fun() -> receive never -> ok end end, 200),
    [?assertEqual(unavailable, check(<<"root">>, <<"x">>)) || _ <- lists:seq(1, 6)].
