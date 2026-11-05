%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_file_remote's path handling (docs/design-files.md, Erlang
%% clients, step 2): random paths of up to 24 pieces drawn from names, ".", "..", runs of
%% "/" and bytes that are not names, some ending in the NUL prim_file's encoding adds, go
%% through last_name/1, and random name lists through names/1. last_name/1 must not raise
%% and must agree with a model that splits the text on "/" and keeps its non-empty
%% pieces: the last name is the last piece, the rest is the text up to and including
%% the "/" before it, or "." for a path of one name, and the path is slashed when a "/"
%% follows its last name. names/1 must give back the list its
%% joined text came from. The seed comes from make check-fuzz.

-module(erx_file_remote_fuzz).
-export([run/1]).

-define(PATHS, 200000).
-define(PIECES, [<<"a">>, <<"bc">>, <<".">>, <<"..">>, <<"...">>, <<"/">>, <<"//">>,
                 <<".a">>, <<"a.">>, <<255>>, <<"\\">>, <<" ">>]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    loop(?PATHS),
    io:format("fuzz: ~b paths ok~n", [?PATHS]).

loop(0) ->
    ok;
loop(Left) ->
    Text = iolist_to_binary([pick(?PIECES) || _ <- lists:seq(1, rand:uniform(25) - 1)]),
    Encoded = case rand:uniform(2) of
                  1 -> <<Text/binary, 0>>;
                  2 -> Text
              end,
    check_last_name(Text, Encoded),
    check_names([pick([<<"a">>, <<"bc">>, <<"...">>, <<"a.b">>]) || _ <- lists:seq(1, rand:uniform(6) - 1)]),
    loop(Left - 1).

check_last_name(Text, Encoded) ->
    Got = erx_file_remote:last_name(Encoded),
    case model(Text) of
        Got -> ok;
        Want -> erlang:error({last_name, Encoded, Got, Want})
    end.

%% The model: the pieces between slashes, empty ones dropped.
model(Text) ->
    case [Piece || Piece <- binary:split(Text, <<"/">>, [global]), Piece =/= <<>>] of
        [] ->
            {Text, <<>>, false};
        Pieces ->
            Last = lists:last(Pieces),
            {rest(Text, Last), Last, binary:last(Text) =:= $/}
    end.

%% The text up to and including the "/" before the last occurrence of Last that is
%% followed only by slashes, or "." when no "/" precedes it.
rest(Text, Last) ->
    Trimmed = re:replace(Text, "/+$", "", [{return, binary}, dollar_endonly]),
    Size = byte_size(Trimmed) - byte_size(Last),
    <<Before:Size/binary, Last/binary>> = Trimmed,
    case Before of
        <<>> -> <<".">>;
        _ -> Before
    end.

check_names(Names) ->
    Joined = iolist_to_binary(lists:join(<<"/">>, Names)),
    case erx_file_remote:names(Joined) of
        Names -> ok;
        Got -> erlang:error({names, Joined, Got})
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
