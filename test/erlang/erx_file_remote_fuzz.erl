%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_file_remote's request function (docs/design-files.md, Erlang
%% clients): batches of random walks of up to 20 names, drawn from plain names, ".",
%% "..", empty names and names that are not UTF-8 or hold "/" or NUL, among stats and
%% mkdirs, go through refused/2 under each set of rights. It must not raise and must
%% agree with a model that reads each request in order: a walk that names ".", ".." or
%% an empty name, or any name the grammar refuses, or more than ?ERX_P9_MAXWELEM names,
%% and a mkdir of such a name, are einval; a write through rights other than rw is erofs;
%% a batch with neither is sent (none). The seed comes from make check-fuzz.

-module(erx_file_remote_fuzz).
-export([run/1]).

-define(BATCHES, 100000).
-define(NAMES, [<<"a">>, <<"bc">>, <<".">>, <<"..">>, <<"...">>, <<>>, <<"a/b">>, <<"a", 0>>,
                <<255>>, <<".a">>, <<"a.">>, <<" ">>]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    loop(?BATCHES),
    io:format("fuzz: ~b batches ok~n", [?BATCHES]).

loop(0) ->
    ok;
loop(Left) ->
    Batch = [request() || _ <- lists:seq(1, rand:uniform(3))],
    Rights = pick([ro, rw, rx]),
    Got = erx_file_remote:refused(Batch, Rights),
    case model(Batch, Rights) of
        Got -> ok;
        Want -> erlang:error({refused, Batch, Rights, Got, Want})
    end,
    loop(Left - 1).

request() ->
    case rand:uniform(3) of
        1 -> {walk, 1, 2, [pick(?NAMES) || _ <- lists:seq(1, rand:uniform(21) - 1)]};
        2 -> {getattr, 1, 16#3fff};
        3 -> {mkdir, 1, pick(?NAMES), 8#755, 0}
    end.

model([], _) ->
    none;
model([Request | Batch], Rights) ->
    case {valid(Request), writes(Request)} of
        {false, _} -> einval;
        {true, true} when Rights =/= rw -> erofs;
        {true, _} -> model(Batch, Rights)
    end.

valid({walk, _, _, Names}) -> length(Names) =< 16 andalso lists:all(fun plain/1, Names);
valid({getattr, _, _}) -> true;
valid({mkdir, _, Name, _, _}) -> plain(Name).

writes({mkdir, _, _, _, _}) -> true;
writes(_) -> false.

plain(Name) ->
    Name =/= <<>> andalso Name =/= <<".">> andalso Name =/= <<"..">> andalso
        binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch andalso
        unicode:characters_to_binary(Name) =:= Name.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
