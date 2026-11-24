%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of root's passphrase line and record (docs/design-ssh.md, "Root's
%% passphrase on the medium"), run by tools/fuzz/erx_boot_passphrase.rb: random,
%% mutated and well-formed files go to erx_boot_passphrase:decode/1, and random and
%% mutated records to erx_passphrase_hash:decode/1. Neither may raise or make an atom;
%% a well-formed line must decode to the record it was made from; every record the
%% line decoder answers must decode back, and every record the record decoder takes
%% must be within the layout's bounds.
-module(erx_boot_passphrase_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(ALPHABET, "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    [{module, _} = code:ensure_loaded(M) || M <- [erx_boot_passphrase, erx_passphrase_hash, binary, lists]],
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    {Line, Record} = line(),
    {File, Mutated} = case rand:uniform(4) of
                          1 -> {rand:bytes(rand:uniform(140) - 1), true};
                          2 -> {mutated(Line, rand:uniform(3)), true};
                          _ -> {Line, false}
                      end,
    Atoms = erlang:system_info(atom_count),
    Said = try erx_boot_passphrase:decode(File) catch C:R -> error({raised, File, C, R}) end,
    record_round(mutated(Record, rand:uniform(3))),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, File}),
    Mutated orelse Said =:= {ok, Record} orelse error({disagrees_with_reference, File, Said, Record}),
    judged(File, Said).

judged(_File, {ok, Bytes}) ->
    {ok, _} = erx_passphrase_hash:decode(Bytes),
    1;
judged(File, {error, too_long}) ->
    byte_size(File) > 128 orelse error({refused_short_file, File}),
    0;
judged(File, {error, not_a_crypt_string}) ->
    byte_size(File) =< 128 orelse error({long_file_not_too_long, File}),
    0;
judged(File, Said) ->
    error({unknown_answer, File, Said}).

record_round(Bytes) ->
    case try erx_passphrase_hash:decode(Bytes) catch C:R -> error({record_raised, Bytes, C, R}) end of
        {ok, #{rounds := Rounds, salt := Salt, hash := <<_:32/binary>>}}
          when Rounds >= 1000, Rounds =< 100000, byte_size(Salt) >= 1, byte_size(Salt) =< 16 ->
            ok;
        {error, malformed} ->
            ok;
        Other ->
            error({record_out_of_bounds, Bytes, Other})
    end.

%% A well-formed line and the record it spells, made independently of the decoder:
%% the hash's 32 bytes spelled in crypt-sha256.c's order.
line() ->
    Rounds = case rand:uniform(3) of 1 -> 5000; _ -> 999 + rand:uniform(99001) end,
    Salt = list_to_binary([pick() || _ <- lists:seq(1, rand:uniform(16))]),
    Hash = rand:bytes(32),
    Field = case Rounds =:= 5000 andalso rand:uniform(2) =:= 1 of
                true -> <<>>;
                false -> <<"rounds=", (integer_to_binary(Rounds))/binary, "$">>
            end,
    End = lists:nth(rand:uniform(3), [<<>>, <<"\n">>, <<"\r\n">>]),
    {<<"$5$", Field/binary, Salt/binary, "$", (spelled(Hash))/binary, End/binary>>,
     <<Rounds:32, Hash/binary, Salt/binary>>}.

pick() -> lists:nth(rand:uniform(64), ?ALPHABET).

spelled(Hash) ->
    B = fun(I) -> binary:at(Hash, I) end,
    Groups = [{0, 10, 20}, {21, 1, 11}, {12, 22, 2}, {3, 13, 23}, {24, 4, 14},
              {15, 25, 5}, {6, 16, 26}, {27, 7, 17}, {18, 28, 8}, {9, 19, 29}],
    Words = [{(B(X) bsl 16) bor (B(Y) bsl 8) bor B(Z), 4} || {X, Y, Z} <- Groups]
        ++ [{(B(31) bsl 8) bor B(30), 3}],
    list_to_binary([[lists:nth(((W bsr (6 * I)) band 63) + 1, ?ALPHABET) || I <- lists:seq(0, N - 1)]
                    || {W, N} <- Words]).

mutated(Bytes, 0) -> Bytes;
mutated(Bytes, N) ->
    mutated(case {rand:uniform(3), byte_size(Bytes)} of
                {_, 0} -> rand:bytes(1);
                {1, Size} -> P = rand:uniform(Size) - 1,
                             <<H:P/binary, _, T/binary>> = Bytes, <<H/binary, (rand:uniform(256) - 1), T/binary>>;
                {2, Size} -> P = rand:uniform(Size) - 1,
                             <<H:P/binary, _, T/binary>> = Bytes, <<H/binary, T/binary>>;
                {3, Size} -> P = rand:uniform(Size + 1) - 1,
                             <<H:P/binary, T/binary>> = Bytes, <<H/binary, (rand:uniform(256) - 1), T/binary>>
            end, N - 1).
