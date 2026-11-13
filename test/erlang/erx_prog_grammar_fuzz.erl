%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Terms near the program protocol's grammar through erx_prog_grammar
%% (docs/design-abi.md#program-protocol): valid start frames, notices and reports
%% with one subterm replaced, random terms as frames of either direction, and start
%% frames whose cwd is drawn near its bound and its rules. Whatever arrives, every
%% check answers ok or {error, {Reason, Kind}} and never raises; a notice or a
%% report draws the same answer from its direction's dispatch as from its own check;
%% a frame a builder returns passes its check; no round makes an atom; and each cwd
%% is judged as reference_cwd/1, which shares no code with the grammar, judges it.
%% The seed comes from make check-fuzz.

-module(erx_prog_grammar_fuzz).
-export([run/1]).

-define(G, erx_prog_grammar).
-define(ROUNDS, 20000).
-define(WARM_ROUNDS, 200).
-define(DEPTH, 3).
-define(PATH_MAX, 4096).

run([Seed]) ->
    rand:seed(exsss, {7, 1, list_to_integer(Seed)}),
    %% Loading the modules a round calls makes atoms, so the count is taken after a few rounds.
    rounds(?WARM_ROUNDS),
    Atoms = erlang:system_info(atom_count),
    rounds(?ROUNDS),
    case erlang:system_info(atom_count) of
        Atoms -> io:format("fuzz: ~p rounds ok~n", [?ROUNDS]);
        After -> error({atoms_made, After - Atoms})
    end.

rounds(N) ->
    lists:foreach(fun(_) ->
                          start_round(mutated(start())),
                          start_round(random_term(?DEPTH)),
                          request_round(random_term(?DEPTH), random_term(?DEPTH)),
                          notice_round(mutated(pick(notices()))),
                          notice_round(random_term(?DEPTH)),
                          report_round(mutated(pick(reports()))),
                          report_round(random_term(?DEPTH)),
                          cwd_round(random_cwd())
                  end, lists:seq(1, N)).

start_round(Value) ->
    Frame = {erx_start, 1, Value},
    answer(?G:check_start(Frame)),
    answer(?G:check_to_program(Frame, [])),
    answer(?G:check_start(Value)),
    case ?G:build_start(Value) of
        {ok, Built} -> ok = ?G:check_start(Built);
        Refused -> answer(Refused)
    end.

request_round(Slot, Value) ->
    answer(?G:check_from_program({erx_prog, 1, Slot, Value})),
    answer(?G:check_request({erx_prog, 1, Slot, Value})),
    case ?G:build_request(Slot, Value) of
        {ok, Built} -> ok = ?G:check_request(Built);
        Refused -> answer(Refused)
    end.

%% A notice goes through the dispatch of frames from the program to its own check.
notice_round(Value) ->
    Frame = {erx_prog, 1, Value},
    Verdict = ?G:check_notice(Frame),
    answer(Verdict),
    Verdict = ?G:check_from_program(Frame),
    case ?G:build_notice(Value) of
        {ok, Built} -> ok = ?G:check_notice(Built);
        Refused -> answer(Refused)
    end.

%% A report goes through the dispatch of frames to the program to its own check.
report_round(Value) ->
    Frame = {erx_prog, 1, Value},
    Verdict = ?G:check_report(Frame),
    answer(Verdict),
    Verdict = ?G:check_to_program(Frame, []),
    case ?G:build_report(Value) of
        {ok, Built} -> ok = ?G:check_report(Built);
        Refused -> answer(Refused)
    end.

%% A start frame's verdict on a cwd matches the reference's, and a refusal names cwd.
cwd_round(Cwd) ->
    case {?G:check_start({erx_start, 1, maps:put(cwd, Cwd, start())}), reference_cwd(Cwd)} of
        {ok, true} -> ok;
        {{error, {_, cwd}}, false} -> ok;
        Other -> error({disagrees_with_reference, Cwd, Other})
    end.

answer(ok) -> ok;
answer({error, {Reason, Kind}}) when is_atom(Reason), is_atom(Kind) -> ok;
answer(Other) -> error({unexpected_answer, Other}).

%% A cwd is a binary of at most PATH_MAX bytes of UTF-8 with no zero byte, "/" or "/"
%% followed by names joined by "/", none of them empty, "." or "..".
reference_cwd(Cwd) when is_binary(Cwd), byte_size(Cwd) =< ?PATH_MAX ->
    unicode:characters_to_binary(Cwd) =:= Cwd
        andalso binary:match(Cwd, <<0>>) =:= nomatch
        andalso normal_absolute(Cwd);
reference_cwd(_) ->
    false.

normal_absolute(<<"/">>) ->
    true;
normal_absolute(<<"/", Names/binary>>) ->
    lists:all(fun(Name) -> not lists:member(Name, [<<>>, <<".">>, <<"..">>]) end,
              binary:split(Names, <<"/">>, [global]));
normal_absolute(_) ->
    false.

%% A valid path near the bound, often with one byte replaced, or a short path of
%% the bytes the rules look at.
random_cwd() ->
    case rand:uniform(3) of
        1 ->
            Len = pick([1, 2, ?PATH_MAX - 1, ?PATH_MAX, ?PATH_MAX + 1, rand:uniform(?PATH_MAX + 4)]),
            Valid = <<"/", (binary:copy(<<"c">>, Len - 1))/binary>>,
            case rand:uniform(2) of
                1 -> Valid;
                2 -> replace_byte(Valid, pick([$/, $., 0, 16#ff, 16#c3, $a]))
            end;
        _ ->
            iolist_to_binary([pick([<<"/">>, <<"a">>, <<".">>, <<"..">>, <<0>>, <<16#ff>>, <<16#c3, 16#a9>>,
                                    <<16#ed, 16#a0, 16#80>>, <<16#c0, 16#80>>])
                              || _ <- lists:seq(1, rand:uniform(8))])
    end.

replace_byte(Bin, Byte) ->
    At = rand:uniform(byte_size(Bin)) - 1,
    <<Before:At/binary, _, After/binary>> = Bin,
    <<Before/binary, Byte, After/binary>>.

%% A start message of every field, one of each descriptor.
start() ->
    #{pid => 2, ppid => 1, pgid => 2,
      argv => [<<"prog">>], env => [<<"HOME=/">>], cwd => <<"/home/u">>,
      spawn => true, sigmask => [sigint], sigignore => [],
      umask => 8#022, data_area => {100, 4},
      fds => [{0, {tty, 1, read}}, {1, {dup, 0}},
              {2, {pipe, write, {1, 2}, #{wend => 1, ring => 101, rpage => 102, size => 16384,
                                         readers => [{0, 103}]}}},
              {3, {pipe, read, {2, 3}, #{rix => 0, lock => 104, wends => 1,
                                        writers => [{1, 105, 106, 65536, {open, 107}},
                                                    {2, 112, 113, 16384, gone}],
                                        readers => []}}},
              {4, {socketpair, {3, 1}, #{rix => 1, lock => 108, wends => 2, writers => [], readers => []},
                   {4, 1}, #{wend => 2, ring => 110, rpage => 111, size => 65536, readers => []}}},
              {5, {file, 7, read_write}}, {6, {dir, 8}}, {7, {socket, 9}}, {8, null}, {9, {mem, 16, 2}}],
      image => {object, 16#ffffffffffffff00}}.

%% A notice of each case (docs/design-pipes.md#the-program-protocol).
notices() ->
    [{closed, 1, 2}, {drained, 1, 2, 3}].

%% A report of each case.
reports() ->
    [{pipe_writer, 1, 2, 3, 101, 102, 16384, 103, open}, {pipe_writer_gone, 1, 2, 3},
     {pipe_reader, 1, 2, 63, 101, gone}, {pipe_reader_gone, 1, 2, 0}, {pipe_lost, 1, 2},
     pipe_server_lost].

%% Term with one subterm, at a random depth, replaced by a random term, or a map's key
%% removed or added.
mutated(Term) ->
    case rand:uniform(4) of
        1 -> random_term(?DEPTH);
        _ -> mutated_inside(Term)
    end.

mutated_inside(Map) when is_map(Map), map_size(Map) > 0 ->
    Key = pick(maps:keys(Map)),
    case rand:uniform(6) of
        1 -> maps:remove(Key, Map);
        2 -> maps:put(random_atom(), random_term(1), Map);
        _ -> maps:put(Key, mutated(maps:get(Key, Map)), Map)
    end;
mutated_inside(Tuple) when is_tuple(Tuple), tuple_size(Tuple) > 0 ->
    At = rand:uniform(tuple_size(Tuple)),
    setelement(At, Tuple, mutated(element(At, Tuple)));
mutated_inside([_ | _] = List) ->
    At = rand:uniform(length(List)),
    {Before, [Element | After]} = lists:split(At - 1, List),
    case rand:uniform(4) of
        1 -> Before ++ After;
        2 -> Before ++ [Element, Element | After];
        _ -> Before ++ [mutated(Element) | After]
    end;
mutated_inside(_) ->
    random_term(?DEPTH).

random_term(0) ->
    random_leaf();
random_term(Depth) ->
    case rand:uniform(8) of
        1 -> [random_term(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        2 -> list_to_tuple([random_term(Depth - 1) || _ <- lists:seq(1, rand:uniform(7) - 1)]);
        3 -> maps:from_list([{random_atom(), random_term(Depth - 1)} || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        4 -> [random_leaf() | random_leaf()];
        _ -> random_leaf()
    end.

random_leaf() ->
    case rand:uniform(4) of
        1 -> pick([-1, 0, 1, 2, 255, 256, 511, 512, 1023, 1024, 16384, 65535, 65536, 16#7fffffff, 16#80000000,
                   16#ffffffff, 16#100000000, 16#7fffffffffffffff, 16#8000000000000000, 16#ffffffffffffffff,
                   16#10000000000000000]);
        2 -> random_atom();
        3 -> pick([<<>>, <<"/">>, <<"a">>, <<"a=b">>, <<"=b">>, <<0>>, <<16#ff>>, <<"/a/../b">>, <<1:3>>]);
        4 -> pick([1.0, self(), make_ref(), {}, [], #{}])
    end.

%% Atoms that exist before any round: the profile's own, and ones it does not name.
random_atom() ->
    pick([read, write, read_write, pipe, socketpair, file, tty, dir, socket, dup, mem, null, object, open, gone,
          true, false, erx_start, erx_prog, sigint, sigterm, sigkill, pid, cwd, fds, wend, readers, writers,
          closed, drained, pipe_writer, pipe_writer_gone, pipe_reader, pipe_reader_gone, pipe_lost,
          pipe_server_lost, erlang, ok, undefined, error]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).
