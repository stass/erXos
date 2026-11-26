%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the Bluetooth domain's stored state (docs/design-bluetooth.md,
%% "Bonds and the store" and "Fuzz targets"): erx_bt_state:decode/1, the reader of what a
%% store returns, untrusted wherever its medium can be written. A round writes a state
%% from random bonds, encodes it, then decodes it as written, cut, lengthened, with an
%% octet changed, or replaced by random bytes, and decodes a state of nine bonds and one
%% in which two bonds share an id. Whatever arrives, decode/1 neither makes an atom nor
%% raises, and:
%%
%% * a state written from a term decodes to that term;
%% * any state decode/1 gives encodes, within bt_state_max, back to its blob byte for
%%   byte, so every octet is read, none past its layout, and nothing decode/1 accepts
%%   is a state encode/1 refuses, which a shared id is.
%%
%% Each round also reads a directory entry's name through erx_bt_state_file:generation/1,
%% the development store's reader of the names its medium lists: a generation's own name,
%% or one made of the store's prefix, random digits, dots and characters. It neither
%% makes an atom nor raises, and a name it reads as a generation is that generation's
%% one name, so no two names are one generation.
%%
%% The seed comes from make check-fuzz.

-module(erx_bt_state_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Atoms = erlang:system_info(atom_count),
    lists:foreach(fun(_) -> round() end, lists:seq(1, ?ROUNDS)),
    Atoms =:= erlang:system_info(atom_count) orelse verdict({atoms_made, erlang:system_info(atom_count) - Atoms}),
    io:format("fuzz: ~b rounds ok, seed ~s~n", [?ROUNDS, Seed]).

round() ->
    State = state(),
    {ok, Blob} = erx_bt_state:encode(State),
    decode(Blob) =:= {ok, State} orelse verdict({decoded_wrongly, State}),
    decode(mutate(Blob)),
    decode(nine()),
    decode(shared()),
    generation(file_name()).

%% Nine bonds, each written as a state of one writes it, under a count of nine.
nine() ->
    #{address := Address} = State = state(),
    Bonds = [begin {ok, <<_:8/binary, Bond/binary>>} = erx_bt_state:encode(State#{bonds := [bond(N)]}), Bond end
             || N <- lists:seq(1, 9)],
    iolist_to_binary([2, Address, 9 | Bonds]).

%% Two bonds of different identities under one id, which no encoder writes.
shared() ->
    #{address := Address} = State = state(),
    Id = binary:encode_hex(rand:bytes(16), lowercase),
    Bonds = [begin {ok, <<_:8/binary, Bond/binary>>} = erx_bt_state:encode(State#{bonds := [(bond(N))#{id := Id}]}), Bond end
             || N <- [1, 2]],
    iolist_to_binary([2, Address, 2 | Bonds]).

decode(Blob) ->
    Result = try erx_bt_state:decode(Blob)
             catch Class:Reason -> verdict({raised, Class, Reason, Blob})
             end,
    case Result of
        {ok, State} ->
            try erx_bt_state:encode(State) of
                {ok, Again} -> Again =:= Blob orelse verdict({reencoded_wrongly, Blob});
                {error, Refused} -> verdict({reencode_refused, Refused, Blob})
            catch EncodeClass:EncodeReason -> verdict({reencode_raised, EncodeClass, EncodeReason, Blob})
            end;
        {error, _} ->
            ok
    end,
    Result.

%% A generation is positive and its name is written back as it was read: a state file's own.
generation(Name) ->
    case try erx_bt_state_file:generation(Name) catch Class:Reason -> verdict({raised, Class, Reason, Name}) end of
        {state, N} when is_integer(N) -> N > 0 andalso "bonds." ++ integer_to_list(N) =:= Name orelse verdict({renamed, Name});
        {new, N} when is_integer(N) ->
            N > 0 andalso "bonds." ++ integer_to_list(N) ++ ".new" =:= Name orelse verdict({renamed, Name});
        other -> ok;
        Other -> verdict({read_as, Other, Name})
    end.

%% A name as a directory lists it: a generation's own, or the prefix and random parts.
file_name() ->
    Digits = [pick(lists:seq($0, $9)) || _ <- lists:seq(1, rand:uniform(25))],
    Suffix = pick(["", ".new", ".new.new", ".old", "."]),
    Parts = [pick(["bonds.", "bonds", ".", "new", "0", Digits, [rand:uniform(16#10FFFF div 2)], [255]]) || _ <- lists:seq(1, rand:uniform(4))],
    pick(["bonds." ++ integer_to_list(rand:uniform(1 bsl 59)) ++ pick(["", ".new"]), "bonds." ++ Digits ++ Suffix,
          lists:append(Parts)]).

mutate(Blob) ->
    case rand:uniform(5) of
        1 -> binary:part(Blob, 0, rand:uniform(byte_size(Blob)) - 1);
        2 -> <<Blob/binary, (rand:bytes(rand:uniform(8)))/binary>>;
        3 -> At = rand:uniform(byte_size(Blob)) - 1,
             <<Head:At/binary, _, Tail/binary>> = Blob,
             <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
        4 -> rand:bytes(rand:uniform(64));
        5 -> Blob
    end.

state() ->
    #{address => <<2#11:2, (rand:uniform(1 bsl 46 - 2)):46>>,
      bonds => [bond(N) || N <- lists:seq(1, rand:uniform(9) - 1)]}.

%% Bond N's identity starts with N, 1 to 9, so no two bonds share one, and a random one is
%% static: its top two bits set and the rest, holding N, neither all zeros nor all ones.
bond(N) ->
    Identity = case pick([public, random]) of
                   public -> {public, <<N, (rand:bytes(5))/binary>>};
                   random -> {random, <<2#11:2, N:6, (rand:bytes(5))/binary>>}
               end,
    #{id => binary:encode_hex(rand:bytes(16), lowercase), identity => Identity, irk => rand:bytes(16), ltk => rand:bytes(16),
      level => pick([authenticated, unauthenticated]), hash => pick([<<>>, rand:bytes(32)]),
      subscriptions => maps:from_list([{{name(), name()}, pick([notify, indicate])} || _ <- lists:seq(1, rand:uniform(3) - 1)])}.

name() ->
    Tail = [pick(lists:seq($a, $z) ++ lists:seq($0, $9) ++ [$_]) || _ <- lists:seq(1, rand:uniform(12) - 1)],
    list_to_binary([pick(lists:seq($a, $z)) | Tail]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

verdict(Term) ->
    io:format("fuzz: ~p~n", [Term]),
    erlang:halt(1).
