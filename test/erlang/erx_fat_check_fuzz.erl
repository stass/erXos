%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the FAT checker, erx_fat_check (docs/design-fsck-fat.md,
%% "Fuzz target"). Its seeds are the clean and damaged volumes of
%% erx_fat_check_tests, laid out by erx_fat_damage, and the volumes fsimg wrote into
%% the directory it is given. A round takes one, mutates its boot sector, FATs and
%% directories (bytes flipped; FAT entries set to free, bad, reserved, end of chain,
%% out of range, themselves or a low cluster, so chains cross and loop), and checks
%% it in a process whose heap limit is the command's, -erx_heap(16), within a
%% deadline. Whatever the volume holds, the check answers its closed set of results,
%% each finding with a message, is not killed, ends in time, and reads only sectors
%% of the volume, at most ?READS_PER_SECTOR times its count of sectors.

-module(erx_fat_check_fuzz).

-export([run/1]).

-define(ROUNDS, 1500).
-define(SECTOR, 512).
-define(HEAP_BYTES, (16 * 1024 * 1024)).
-define(DEADLINE_MS, 10000).
-define(READS_PER_SECTOR, 8).
-define(MUTATIONS, 6).

run([Seed, Directory]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Volumes = seeds(Directory),
    [round_of(lists:nth(rand:uniform(length(Volumes)), Volumes)) || _ <- lists:seq(1, ?ROUNDS)],
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

%% Each seed as {Sectors, Data}: its count of sectors and its non-zero sectors.
seeds(Directory) ->
    Clean = [erx_fat_damage:volume(Type, erx_fat_check_tests:tree()) || Type <- [16, 32]],
    Damaged = [Damage(lists:nth(Type div 16, Clean)) || {_, Type, Damage, _} <- erx_fat_check_tests:cases()],
    Ours = [{erx_fat_damage:sectors(V), maps:get(data, V)} || V <- Clean ++ Damaged],
    Ours ++ [image(filename:join(Directory, Image)) || Image <- filelib:wildcard("*.img", Directory)].

image(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Count = byte_size(Bytes) div ?SECTOR,
    {Count, maps:from_list([{I, S} || I <- lists:seq(0, Count - 1),
                                      S <- [binary:part(Bytes, I * ?SECTOR, ?SECTOR)], S =/= <<0:(?SECTOR * 8)>>])}.

round_of({Sectors, Data}) ->
    Mutated = lists:foldl(fun(_, D) -> mutated(D) end, Data, lists:seq(1, rand:uniform(?MUTATIONS))),
    Volume = {Sectors, Mutated},
    case checked(Volume) of
        {answer, Answer} -> valid(Answer) orelse error({bad_answer, Answer});
        Failure -> dump(Volume), error(Failure)
    end.

%% One mutation of a written sector: a byte flipped, or a FAT-sized word set to a
%% telling value.
mutated(Data) ->
    Sector = lists:nth(rand:uniform(map_size(Data)), maps:keys(Data)),
    Bytes = maps:get(Sector, Data),
    Offset = rand:uniform(?SECTOR div 2) * 2 - 2,
    <<Before:Offset/binary, Old:16/little, After/binary>> = Bytes,
    New = case rand:uniform(3) of
              1 -> Old bxor (1 bsl (rand:uniform(16) - 1));
              2 -> lists:nth(rand:uniform(8), [0, 1, 16#fff6, 16#fff7, 16#ffff, 16#fff0, 16#7fff, Offset div 2]);
              3 -> rand:uniform(40) + 1
          end,
    Data#{Sector => <<Before/binary, New:16/little, After/binary>>}.

%% The check in a process of the command's heap limit, within the deadline; reads
%% outside the volume or past the work bound end it.
checked({Sectors, Data}) ->
    Read = fun(Index) when Index >= 0, Index < Sectors ->
                   Count = case get(reads) of undefined -> 1; N -> N + 1 end,
                   Count =< ?READS_PER_SECTOR * Sectors orelse exit(work_bound),
                   put(reads, Count),
                   {ok, maps:get(Index, Data, <<0:(?SECTOR * 8)>>)};
              (Index) ->
                   exit({read_outside, Index})
           end,
    Self = self(),
    {Pid, Ref} = spawn_opt(fun() -> Self ! {self(), erx_fat_check:check(Read, Sectors)} end,
                           [monitor, {max_heap_size, #{size => ?HEAP_BYTES div erlang:system_info(wordsize),
                                                        kill => true, error_logger => false}}]),
    receive
        {Pid, Answer} -> erlang:demonitor(Ref, [flush]), {answer, Answer};
        {'DOWN', Ref, process, Pid, Why} -> {died, Why}
    after ?DEADLINE_MS ->
        exit(Pid, kill),
        hang
    end.

valid({ok, Findings}) -> is_list(Findings) andalso lists:all(fun(F) -> is_binary(erx_fat_check:message(F)) end, Findings);
valid({fatal, Fatal}) -> is_binary(erx_fat_check:message(Fatal));
valid({refused, _Reason}) -> true;
valid(_Other) -> false.

%% The failing volume, kept in the working directory to reproduce the round.
dump({Sectors, Data}) ->
    Image = << <<(maps:get(I, Data, <<0:(?SECTOR * 8)>>))/binary>> || I <- lists:seq(0, Sectors - 1) >>,
    ok = file:write_file("erx_fat_check_failure.img", Image).
