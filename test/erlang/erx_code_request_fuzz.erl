%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random request terms through erx_code_store:read_request/1, the code service's one reader
%% of what arrives from the host link, the manifest reader read_manifest/1 among them. Each
%% round builds a request of one of the four kinds, well formed, and then changes none, one or
%% several things: a hash's length, a name's length or one of its bytes, a list's length about
%% its bound, its tail, an entry's shape, a duplicated name, an integer's sign or type, a
%% piece's size, or the whole term. Whatever arrives, read_request/1 answers {ok, Request} or
%% {error, Reason} with Reason one of its fixed shapes, never a crash, and agrees with
%% reference/1: a model of the same rules written from the design's limits with regular
%% expressions and length/1 instead of the reader's bounded walk, so a bound the reader
%% drops or misplaces shows as a disagreement. The seed comes from make check-fuzz.

-module(erx_code_request_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
%% The fewest rounds that must be accepted, so a change to the generator cannot leave the
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(MANIFEST_MAX, 1024).
-define(PIECE_MAX, 65536).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    Term = mutate(request(), rand:uniform(4) - 1),
    Said = erx_code_store:read_request(Term),
    shape(Said),
    case {Said, reference(Term)} of
        {{ok, Request}, {ok, Request}} -> accepted;
        {{error, Reason}, {error, Reason}} -> refused;
        %% Past its bound the reader stops walking, so a long list's reason is too_many
        %% whatever lies beyond; the reference walks it all.
        {{error, {bad_manifest, too_many}}, {error, _}} -> refused;
        {_, Reference} -> error({disagrees_with_reference, Term, Said, Reference})
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).

%% Requests, well formed

request() ->
    case rand:uniform(4) of
        1 -> {missing, [hash() || _ <- lists:seq(1, count())]};
        2 -> piece();
        3 -> {load, manifest()};
        4 -> {history, pick([4, 5, rand:uniform(1 bsl 40)]), name()}
    end.

hash() -> rand:bytes(32).

count() -> pick([0, 1, 2, rand:uniform(16), ?MANIFEST_MAX]).

name() ->
    Alphabet = <<"abcxyzABCXYZ0189_.@">>,
    Length = pick([1, 2, rand:uniform(32), 255]),
    << <<(binary:at(Alphabet, rand:uniform(byte_size(Alphabet)) - 1))>> || _ <- lists:seq(1, Length) >>.

manifest() ->
    Length = max(1, count()),
    [{<<(name())/binary, (integer_to_binary(Index))/binary>>, hash()} || Index <- lists:seq(1, Length)].

piece() ->
    Bytes = pick([1, 2, rand:uniform(100), ?PIECE_MAX]),
    Size = pick([Bytes, Bytes + rand:uniform(1 bsl 24)]),
    {put, hash(), Size, pick([0, rand:uniform(1 bsl 30)]), rand:bytes(Bytes)}.

%% Mutations

mutate(Term, 0) -> Term;
mutate(Term, N) -> mutate(mutate_one(Term), N - 1).

%% A mutation changes a term the generator built or an earlier mutation left, so each
%% clause takes the shape it changes and anything else falls to the last clause. A guard
%% `length(List) >= 0` holds only for a proper list, since length/1 fails in a guard on any
%% other term.

mutate_one({missing, Hashes}) when is_list(Hashes), length(Hashes) >= 0 ->
    pick([{missing, change_list(Hashes, fun hash/0)}, {missing, list_to_tuple(Hashes)},
          {missing, [change_binary(Hash) || Hash <- Hashes]}, whole()]);
mutate_one({put, Hash, Size, Offset, Piece}) ->
    pick([{put, change_binary(Hash), Size, Offset, Piece}, {put, Hash, change_integer(Size), Offset, Piece},
          {put, Hash, Size, change_integer(Offset), Piece}, {put, Hash, Size, Offset, change_binary(Piece)},
          {put, Hash, Size, Offset, rand:bytes(pick([0, ?PIECE_MAX + 1]))},
          {put, Hash, Size, Offset}, whole()]);
mutate_one({load, Manifest}) when is_list(Manifest), length(Manifest) >= 0 ->
    pick([{load, change_list(Manifest, fun() -> {name(), hash()} end)}, {load, change_entry(Manifest)},
          {load, duplicate(Manifest)}, {load, list_to_tuple(Manifest)}, whole()]);
mutate_one({history, DomainId, Name}) when is_binary(Name), byte_size(Name) > 0 ->
    pick([{history, change_integer(DomainId), Name}, {history, DomainId, change_name(Name)},
          {history, DomainId, list_to_tuple(binary_to_list(Name))}, whole()]);
mutate_one(Term) ->
    pick([Term, whole()]).

whole() -> pick([missing, {}, [], <<"load">>, {load}, {load, a, b}, 4, make_ref(), {put, 1, 2, 3, 4}]).

%% A list one cell longer or shorter, near its bound, emptied, or with an improper tail.
change_list(List, New) ->
    pick([[New() | List], tl_or_empty(List), [], List ++ [New() || _ <- lists:seq(1, max(0, ?MANIFEST_MAX + 1 - length(List)))],
          improper(List)]).

tl_or_empty([]) -> [];
tl_or_empty([_ | Rest]) -> Rest.

improper([]) -> tail;
improper(List) -> lists:droplast(List) ++ improper_tail(lists:last(List)).

improper_tail(Last) -> [Last | tail].

change_entry([]) -> [];
change_entry(Manifest) ->
    Index = rand:uniform(length(Manifest)),
    case lists:nth(Index, Manifest) of
        {Name, Hash} when is_binary(Name), byte_size(Name) > 0 -> replace(Manifest, Index, changed_entry(Name, Hash));
        _ -> Manifest
    end.

changed_entry(Name, Hash) ->
    pick([{change_name(Name), Hash}, {Name, change_binary(Hash)}, {Name}, {Name, Hash, x}, Name,
                  {binary_to_list(Name), Hash}]).

replace(List, Index, Element) ->
    lists:sublist(List, Index - 1) ++ [Element | lists:nthtail(Index, List)].

duplicate([]) -> [];
duplicate([{Name, _Hash} | _] = Manifest) -> Manifest ++ [{Name, hash()}];
duplicate(Manifest) -> Manifest.

change_name(Name) ->
    pick([<<>>, <<Name/binary, Name/binary, (binary:copy(<<"m">>, 256))/binary>>,
          binary:copy(<<"m">>, 256), set_byte(Name, pick([$/, $\s, 0, 16#7f, 16#c3, $-, $:]))]).

set_byte(Name, Byte) ->
    At = rand:uniform(byte_size(Name)) - 1,
    <<Before:At/binary, _, After/binary>> = Name,
    <<Before/binary, Byte, After/binary>>.

change_binary(Binary) when not is_binary(Binary); Binary =:= <<>> -> pick([<<>>, <<1:7>>]);
change_binary(Binary) ->
    pick([binary:part(Binary, 0, byte_size(Binary) - 1), <<Binary/binary, 0>>, <<Binary/binary, 1:1>>,
          binary_to_list(Binary)]).

change_integer(Integer) when not is_integer(Integer) -> pick([0, 1]);
change_integer(Integer) -> pick([-Integer, 0, -1, Integer * 1.0, integer_to_binary(Integer)]).

%% The reader's answers

shape({ok, {missing, Hashes}}) when is_list(Hashes) -> ok;
shape({ok, {put, _, _, _, _}}) -> ok;
shape({ok, {load, [_ | _]}}) -> ok;
shape({ok, {history, _, _}}) -> ok;
shape({error, bad_request}) -> ok;
shape({error, {bad_manifest, Why}}) when Why =:= not_a_list; Why =:= empty; Why =:= too_many -> ok;
shape({error, {bad_manifest, {Why, Index}}})
  when (Why =:= bad_entry orelse Why =:= duplicate_name), is_integer(Index), Index >= 1 -> ok;
shape(Said) -> error({bad_shape, Said}).

%% The reference

reference({missing, Hashes}) ->
    case proper_length(Hashes) of
        {ok, Length} when Length =< ?MANIFEST_MAX ->
            case lists:all(fun reference_hash/1, Hashes) of
                true -> {ok, {missing, Hashes}};
                false -> {error, bad_request}
            end;
        _ -> {error, bad_request}
    end;
reference({put, Hash, Size, Offset, Piece} = Request) ->
    Valid = reference_hash(Hash) andalso is_integer(Size) andalso Size >= 1 andalso is_integer(Offset)
        andalso Offset >= 0 andalso is_binary(Piece) andalso byte_size(Piece) >= 1
        andalso byte_size(Piece) =< ?PIECE_MAX,
    case Valid of
        true -> {ok, Request};
        false -> {error, bad_request}
    end;
reference({load, Manifest}) ->
    case proper_length(Manifest) of
        {ok, 0} -> {error, {bad_manifest, empty}};
        {ok, Length} when Length > ?MANIFEST_MAX -> {error, {bad_manifest, too_many}};
        {ok, _} -> reference_entries(Manifest);
        error -> {error, {bad_manifest, not_a_list}}
    end;
reference({history, DomainId, Name} = Request) when is_integer(DomainId) ->
    case reference_name(Name) of
        true -> {ok, Request};
        false -> {error, bad_request}
    end;
reference(_Term) ->
    {error, bad_request}.

reference_entries(Manifest) ->
    Problems = [{Why, Index} || {Index, Entry} <- lists:enumerate(Manifest),
                                Why <- [problem(Entry, lists:sublist(Manifest, Index - 1))], Why =/= none],
    case Problems of
        [] -> {ok, {load, Manifest}};
        [First | _] -> {error, {bad_manifest, First}}
    end.

%% What is wrong with an entry, given the entries before it.
problem(Entry, Earlier) ->
    case reference_entry(Entry) of
        false -> bad_entry;
        true ->
            case lists:keymember(element(1, Entry), 1, Earlier) of
                true -> duplicate_name;
                false -> none
            end
    end.

reference_entry({Name, Hash}) -> reference_name(Name) andalso reference_hash(Hash);
reference_entry(_) -> false.

reference_hash(Hash) -> is_binary(Hash) andalso bit_size(Hash) =:= 256.

reference_name(Name) when is_binary(Name) ->
    re:run(Name, <<"\\A[A-Za-z0-9_.@]{1,255}\\z">>) =/= nomatch;
reference_name(_) ->
    false.

proper_length(Term) ->
    try length(Term) of
        Length -> {ok, Length}
    catch
        error:badarg -> error
    end.
