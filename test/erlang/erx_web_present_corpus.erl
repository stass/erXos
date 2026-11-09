%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The machine's side of test/host/web_present_test.rb: a seeded corpus of
%% values of every presentation erx_present:marks/0 declares, each written
%% as one line of its type, then x and the hexadecimal of its canonical text
%% (erx_present:text/2), of its link (erx_present:uri/2) and of its path's
%% /proc entry names joined by "/" (erx_present:path/2 and
%% erx_procfs_core:name/1). Module names reach for the bytes the encodings
%% treat apart: ".", "/", "%", a leading "." and non-ASCII.
-module(erx_web_present_corpus).
-export([run/0]).

-define(VALUES, 300).

run() ->
    rand:seed(exsss, {1, 2, 3}),
    Lines = [line(Type, Value) || {Type, _Pattern} <- erx_present:marks(),
                                  Value <- [value(Type) || _ <- lists:seq(1, ?VALUES)]],
    ok = file:write_file("out.txt", Lines),
    halt(0).

line(Type, Value) ->
    Path = lists:join($/, [erx_procfs_core:name(Segment) || Segment <- erx_present:path(Type, Value)]),
    [atom_to_binary(Type), [[$\s, $x, binary:encode_hex(iolist_to_binary(Text))]
                            || Text <- [erx_present:text(Type, Value), erx_present:uri(Type, Value), Path]], $\n].

value(pid) -> list_to_pid("<0." ++ integer_to_list(rand:uniform(1 bsl 28) - 1) ++ "."
                          ++ integer_to_list(rand:uniform(1 bsl 13) - 1) ++ ">");
value(domain) -> rand:uniform(1 bsl 32) - 1;
value(budget) -> rand:uniform(1 bsl 32 - 1);
value(group) -> rand:uniform(1 bsl 32 - 1);
value(module) -> {value(domain), name()}.

name() ->
    Pieces = [<<".">>, <<"..">>, <<"/">>, <<"%">>, <<"%2E">>, <<"a">>, <<"Z9_+,:=@-">>, <<" ">>,
              <<"\x{e9}"/utf8>>, <<"\x{1F600}"/utf8>>],
    %% At most twelve pieces of nine bytes, within module_name's 255.
    iolist_to_binary([lists:nth(rand:uniform(length(Pieces)), Pieces) || _ <- lists:seq(1, rand:uniform(12))]).
