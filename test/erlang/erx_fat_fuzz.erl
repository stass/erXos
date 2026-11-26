%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the FAT server's read path, erx_fat (docs/design-storage.md,
%% "Removable media: FAT"). Its seeds are the volumes test/fixtures/fat_volumes.rb
%% writes into the directory it is given. A round takes one, mutates its boot
%% sector, FATs, directories and data (bytes flipped, 16-bit words set to random or
%% telling values: free, bad, end of chain, the edges of a cluster number), mounts
%% it, walks every directory it reaches to a depth of 8 and reads every file's first
%% 64 KiB. Whatever the volume holds, the server never raises and makes no atom,
%% reads no sector outside the volume, serves no name holding a slash or a NUL, and
%% answers only its closed set of findings; an unmutated seed reads hello.txt as the
%% tree holds it. A mounted volume also runs the ownership check, and one it finds
%% no tree is one fsimg's verify (ERX_FSIMG) also rejects. The seed comes from make
%% check-fuzz.

-module(erx_fat_fuzz).

-export([run/1]).

-define(ROUNDS, 4000).
-define(MIN_MOUNTED, ?ROUNDS div 10).
-define(SECTOR, 512).
-define(DEPTH, 8).
-define(READ, 65536).
-define(FINDINGS, [not_its_volume, does_not_read, read_failed, not_dir, not_found, is_dir]).

run([Seed, Directory]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Volumes = [volume(Directory, Image) || Image <- filelib:wildcard("*.img", Directory)],
    Volumes =/= [] orelse error(no_seed_volumes),
    {ok, Hello} = file:read_file(filename:join([Directory, "tree", "hello.txt"])),
    %% Loaded before the first round counts atoms, since loading a module makes its atoms.
    [{module, _} = code:ensure_loaded(Module) || Module <- [erx_fat, erx_fat_read, erx_fat_alloc, binary, lists, maps,
                                                             unicode, calendar]],
    Mounted = lists:sum([round_of(lists:nth(rand:uniform(length(Volumes)), Volumes), Hello)
                         || _ <- lists:seq(1, ?ROUNDS)]),
    case Mounted >= ?MIN_MOUNTED of
        true -> io:format("fuzz: ~p rounds ok, ~p mounted~n", [?ROUNDS, Mounted]);
        false -> error({too_few_mounted, Mounted})
    end.

%% A seed volume: its non-zero sectors by index, and its count of sectors.
volume(Directory, Image) ->
    {ok, Bytes} = file:read_file(filename:join(Directory, Image)),
    Count = byte_size(Bytes) div ?SECTOR,
    Sectors = maps:from_list([{Index, Sector} || Index <- lists:seq(0, Count - 1),
                                                  Sector <- [binary:part(Bytes, Index * ?SECTOR, ?SECTOR)],
                                                  Sector =/= <<0:(?SECTOR * 8)>>]),
    {Sectors, Count}.

round_of({Seed, Count}, Hello) ->
    {Sectors, Mutated} = case rand:uniform(8) of
                             1 -> {Seed, false};
                             _ -> {mutated(Seed, rand:uniform(6)), true}
                         end,
    Read = reader(Sectors, Count),
    Atoms = erlang:system_info(atom_count),
    Said = try
               case erx_fat:mount(Read, Count) of
                   {ok, Fat} -> owned(Fat, Sectors, Count), {mounted, tree(Fat, erx_fat:root(Fat), ?DEPTH)};
                   {error, Finding} -> {refused, [finding(Finding)]}
               end
           catch Class:Reason -> error({raised, Class, Reason, changed(Seed, Sectors)})
           end,
    erlang:system_info(atom_count) =:= Atoms orelse error(atoms_made),
    Mutated orelse lists:member({<<"hello.txt">>, {ok, Hello}}, element(2, Said))
        orelse error({seed_misread, Said}),
    case Said of
        {mounted, _} -> 1;
        _ -> 0
    end.

%% The ownership check over a mounted volume: it answers one of its outcomes, and a
%% volume it finds no tree is one fsimg's verify (ERX_FSIMG) also rejects.
owned(Fat, Sectors, Count) ->
    case erx_fat:check(Fat) of
        ok -> ok;
        {read_only, too_large} -> error(too_large_seed);
        {error, read_failed} -> ok;
        {read_only, tree} ->
            Path = filename:absname("owned.img"),
            Zero = <<0:(?SECTOR * 8)>>,
            ok = file:write_file(Path, [maps:get(Index, Sectors, Zero) || Index <- lists:seq(0, Count - 1)]),
            Port = open_port({spawn_executable, os:getenv("ERX_FSIMG")},
                             [{args, ["W", "-f", Path]}, exit_status, stderr_to_stdout, binary]),
            case verified(Port) of
                0 -> error({tree_refused_but_fsimg_passes, Path});
                _ -> ok
            end
    end.

verified(Port) ->
    receive
        {Port, {data, _}} -> verified(Port);
        {Port, {exit_status, Status}} -> Status
    end.

%% Every name the walk reaches with what its read answered, for files, or the
%% finding its listing answered.
tree(_Fat, _Dir, 0) ->
    [];
tree(Fat, Dir, Depth) ->
    case erx_fat:list(Dir, Fat) of
        {ok, Entries} ->
            lists:append([begin
                              served(Name) orelse error({served, Name}),
                              {ok, Node} =:= erx_fat:walk(Dir, Name, Fat) orelse error({walk_differs, Name}),
                              case erx_fat:attr(Node) of
                                  #{kind := dir} -> tree(Fat, Node, Depth - 1);
                                  #{kind := file} ->
                                      answer(erx_fat:read(Node, rand:uniform(4096), ?READ, Fat)),
                                      [{Name, answer(erx_fat:read(Node, 0, ?READ, Fat))}]
                              end
                          end || {Name, Node} <- Entries]);
        {error, Finding} ->
            [finding(Finding)]
    end.

%% A name the server may serve: no slash, no control, not . or .., and no space
%% first or space or period last.
served(Name) ->
    Chars = unicode:characters_to_list(Name),
    is_list(Chars) andalso Chars =/= [] andalso Name =/= <<".">> andalso Name =/= <<"..">>
        andalso not lists:any(fun(C) -> C =:= $/ orelse C < 16#20 end, Chars)
        andalso hd(Chars) =/= $\s andalso not lists:member(lists:last(Chars), " .").

answer({ok, Bytes}) when byte_size(Bytes) =< ?READ -> {ok, Bytes};
answer({error, Finding}) -> finding(Finding);
answer(Other) -> error({unknown_answer, Other}).

finding(Finding) ->
    lists:member(Finding, ?FINDINGS) orelse error({unknown_finding, Finding}),
    {error, Finding}.

reader(Sectors, Count) ->
    fun(Index) when is_integer(Index), Index >= 0, Index < Count -> {ok, maps:get(Index, Sectors, <<0:(?SECTOR * 8)>>)};
       (Index) -> error({outside_the_volume, Index})
    end.

changed(Seed, Sectors) -> maps:keys(maps:filter(fun(Index, Sector) -> maps:get(Index, Seed, none) =/= Sector end, Sectors)).

mutated(Sectors, 0) -> Sectors;
mutated(Sectors, Left) ->
    %% The boot sector an eighth of the time, else any sector the seed holds.
    Indexes = maps:keys(Sectors),
    Index = case rand:uniform(8) > 1 of
                true -> lists:nth(rand:uniform(length(Indexes)), Indexes);
                false -> 0
            end,
    mutated(Sectors#{Index => mutated_sector(maps:get(Index, Sectors, <<0:(?SECTOR * 8)>>))}, Left - 1).

mutated_sector(Sector) ->
    At = rand:uniform(?SECTOR div 2) * 2 - 2,
    <<Before:At/binary, Word:16/little, After/binary>> = Sector,
    New = case rand:uniform(4) of
              1 -> Word bxor (1 bsl (rand:uniform(16) - 1));
              2 -> rand:uniform(16#10000) - 1;
              3 -> lists:nth(rand:uniform(8), [0, 1, 2, 16#fff7, 16#fff8, 16#ffff, 16#8000, 16#0fff]);
              4 -> Word bxor 16#2f2f
          end,
    <<Before/binary, New:16/little, After/binary>>.
