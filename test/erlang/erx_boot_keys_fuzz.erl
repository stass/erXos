%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the decoder of root's authorized_keys, erx_boot_keys
%% (docs/design-ssh.md, "Verification"). A round writes a file of lines of known
%% effect (keys, comments, blank lines, options, other key types, keys that do not
%% decode, lines past the bound, CRLF endings, a last line without its line feed) and
%% hands it to the decoder as written, mutated (bytes flipped, cut, inserted), or
%% replaced by random bytes. Whatever arrives, the decoder never raises and makes no
%% atom; every blob it returns is a 51-byte ssh-ed25519 key blob whose base64 the file
%% holds, so no key comes from anywhere but a line the user wrote; there are at most
%% 16; and each finding names a line of the file, in order, with a reason of the
%% closed set. A file as written decodes to what its lines say. The seed comes from
%% make check-fuzz.

-module(erx_boot_keys_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(TYPE, <<"ssh-ed25519">>).
-define(FILE_MAX, 16384).
-define(LINE_MAX, 1024).
-define(KEYS_MAX, 16).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% 1 when the round's file gave at least one key.
round_of() ->
    {Written, Expected} = file(),
    {File, Mutated} = case rand:uniform(4) of
                          1 -> {rand:bytes(rand:uniform(200) - 1), true};
                          2 -> {mutated(Written, rand:uniform(4)), true};
                          _ -> {Written, false}
                      end,
    Atoms = erlang:system_info(atom_count),
    Said = try erx_boot_keys:decode(File) catch Class:Reason -> error({raised, File, Class, Reason}) end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, File}),
    judged(File, Said),
    Mutated orelse Said =:= Expected orelse error({differs, File, Said, Expected}),
    case Said of
        {ok, [_ | _], _} -> 1;
        _ -> 0
    end.

judged(File, {ok, Blobs, Findings}) ->
    [key_blob(Blob) orelse error({not_a_key_blob, File, Blob}) || Blob <- Blobs],
    [binary:match(File, base64:encode(Blob)) =/= nomatch orelse error({key_not_written, File, Blob})
     || Blob <- Blobs],
    length(Blobs) =< ?KEYS_MAX orelse error({too_many_keys_returned, File}),
    Lines = length(binary:matches(File, <<"\n">>)) + 1,
    Numbers = [Number || {Number, Reason} <- Findings,
                         lists:member(Reason, [not_a_plain_key, does_not_decode, line_too_long])],
    length(Numbers) =:= length(Findings) andalso Numbers =:= lists:usort(Numbers)
        andalso lists:all(fun(N) -> N >= 1 andalso N =< Lines end, Numbers)
        orelse error({bad_findings, File, Findings});
judged(File, {error, too_long}) ->
    byte_size(File) > ?FILE_MAX orelse error({refused_short_file, File});
judged(_File, {error, too_many_keys}) ->
    ok;
judged(File, Said) ->
    error({unknown_answer, File, Said}).

key_blob(<<11:32, "ssh-ed25519", 32:32, _:32/binary>>) -> true;
key_blob(_) -> false.

%% A file of lines and what decoding it must give.
file() ->
    Count = case rand:uniform(10) of
                1 -> 15 + rand:uniform(4);
                2 -> 40 + rand:uniform(40);
                _ -> rand:uniform(12) - 1
            end,
    Lines = [line() || _ <- lists:seq(1, Count)],
    Ended = ended(Lines),
    File = iolist_to_binary([Text || {Text, _} <- Ended]),
    {File, expected(File, Ended)}.

%% The last line loses its ending a quarter of the time.
ended([]) -> [];
ended(Lines) ->
    {Init, [{Text, Ending, Effect}]} = lists:split(length(Lines) - 1, Lines),
    Last = case rand:uniform(4) of 1 -> {Text, <<>>, Effect}; _ -> {Text, Ending, Effect} end,
    [{<<Line/binary, End/binary>>, effect(byte_size(Line) + byte_size(End), Effect)}
     || {Line, End, Effect} <- Init ++ [Last]].

%% A line's effect, once its length with its line feed is known.
effect(Length, _Effect) when Length > ?LINE_MAX -> {skipped, line_too_long};
effect(_Length, Effect) -> Effect.

expected(File, _Lines) when byte_size(File) > ?FILE_MAX -> {error, too_long};
expected(_File, Lines) ->
    Numbered = lists:zip(lists:seq(1, length(Lines)), [Effect || {_, Effect} <- Lines]),
    Keys = [Blob || {_, {key, Blob}} <- Numbered],
    case length(Keys) > ?KEYS_MAX of
        true -> {error, too_many_keys};
        false -> {ok, Keys, [{N, Reason} || {N, {skipped, Reason}} <- Numbered]}
    end.

%% {Text, Ending, Effect}: the line without its ending, its ending, and what the
%% decoder makes of it within the line bound.
line() ->
    Ending = case rand:uniform(3) of 1 -> <<"\r\n">>; _ -> <<"\n">> end,
    Blob = <<11:32, ?TYPE/binary, 32:32, (rand:bytes(32))/binary>>,
    Key = base64:encode(Blob),
    case rand:uniform(10) of
        1 -> {blanks(), Ending, ignored};
        2 -> {<<(blanks())/binary, "#", (text(80))/binary>>, Ending, ignored};
        3 -> {<<"restrict ", ?TYPE/binary, " ", Key/binary>>, Ending, {skipped, not_a_plain_key}};
        4 -> {<<"ssh-rsa ", Key/binary, (comment())/binary>>, Ending, {skipped, not_a_plain_key}};
        5 -> {<<?TYPE/binary, (blanks1())/binary, (base64:encode(rand:bytes(51)))/binary>>, Ending,
              {skipped, does_not_decode}};
        6 -> {<<?TYPE/binary, " ", (binary:part(Key, 0, rand:uniform(67)))/binary>>, Ending,
              {skipped, does_not_decode}};
        7 -> {<<"#", (binary:copy(<<"c">>, 1000 + rand:uniform(60)))/binary>>, Ending, ignored};
        _ -> {<<(blanks())/binary, ?TYPE/binary, (blanks1())/binary, Key/binary, (comment())/binary>>, Ending,
              {key, Blob}}
    end.

blanks() -> << <<(element(rand:uniform(2), {$\s, $\t}))>> || _ <- lists:seq(1, rand:uniform(4) - 1) >>.

blanks1() -> <<" ", (blanks())/binary>>.

comment() ->
    case rand:uniform(3) of
        1 -> <<>>;
        _ -> <<(blanks1())/binary, (text(60))/binary>>
    end.

%% Up to Max bytes of anything but a line feed; a carriage return last would be
%% dropped with a CRLF ending, so the text never ends in one.
text(Max) ->
    << <<(case B of $\n -> $x; $\r -> $y; _ -> B end)>> || <<B>> <= rand:bytes(rand:uniform(Max)) >>.

mutated(Bytes, 0) -> Bytes;
mutated(<<>>, _Left) -> rand:bytes(rand:uniform(8));
mutated(Bytes, Left) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Bytes,
    Next = case rand:uniform(5) of
               1 -> <<Before/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), After/binary>>;
               2 -> <<Before/binary, After/binary>>;
               3 -> <<Before/binary, (element(rand:uniform(5), {$\n, $\r, $\s, $\t, $#})), Byte, After/binary>>;
               4 -> <<Before/binary, (rand:bytes(rand:uniform(8)))/binary, After/binary>>;
               5 -> Before
           end,
    mutated(Next, Left - 1).
