%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the login facet's request decoding (docs/design-login.md,
%% "Security" and "Verification"): erx_login_facet:admit/3 over decode/1, the reader
%% of what a front end sends the login service. A round builds a request: a third are
%% requests the interface takes, their binaries at and near each bound; the rest are
%% those requests with one argument moved past its bound, given a byte outside the
%% name alphabet or another type, an argument dropped or added, and random terms.
%% Whatever arrives, admit/3 returns and never raises, makes no atom, forwards exactly
%% what in_bounds/1 below takes and refuses the rest badarg; operation/1 names the
%% operation of what it forwards and error for anything else. The bounds come from the
%% generated ABI header; the seed from make check-fuzz.

-module(erx_login_facet_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 30000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
%% One byte past a system identifier's bound (docs/design-system.md, "Identifiers"), so
%% names reach the bound and cross it; erx_ident:new/1 is the oracle that judges them.
-define(IDENT_EDGE, (?ERX_IDENTIFIER_MAX + 1)).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    {ok, cookie} = erx_login_facet:operation(cookie),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(request()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

state() -> #{service => self(), grant => #{}}.

round_of(Request) ->
    Atoms = erlang:system_info(atom_count),
    Said = try erx_login_facet:admit(Request, self(), state())
           catch Class:Reason -> error({admit_raised, Class, Reason})
           end,
    Operation = try erx_login_facet:operation(Request)
                catch OpClass:OpReason -> error({operation_raised, OpClass, OpReason})
                end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Request}),
    case {Said, Operation, in_bounds(Request)} of
        {{forward, _, {login, Request, _, _}, _}, {ok, Op}, true} ->
            Op =:= operation_of(Request) orelse error({operation_disagrees, Request, Op}),
            accepted;
        {{refuse, badarg, _}, error, false} -> refused;
        {{forward, _, _, _}, _, false} -> error({accepted_out_of_bounds, Request});
        {_, _, true} -> error({refused_in_bounds, Request, Said, Operation});
        _Disagreeing -> error({operation_disagrees, Request, Said, Operation})
    end.

operation_of(cookie) -> cookie;
operation_of(Request) -> element(1, Request).

%% The interface, restated from abi/services/login.txt.
in_bounds(cookie) -> true;
in_bounds({key_ok, User, Blob}) -> user(User) andalso bytes(Blob, 1, ?ERX_LOGIN_BLOB_MAX);
in_bounds({login_key, User, Exchange, Alg, Blob, Sig, Peer}) ->
    user(User) andalso bytes(Exchange, 1, ?ERX_LOGIN_EXCHANGE_MAX) andalso bytes(Alg, 1, ?ERX_LOGIN_BLOB_MAX)
        andalso bytes(Blob, 1, ?ERX_LOGIN_BLOB_MAX) andalso bytes(Sig, 1, ?ERX_LOGIN_BLOB_MAX)
        andalso bytes(Peer, 0, ?ERX_LOGIN_PEER_MAX);
in_bounds({login_passphrase, User, Passphrase, Peer}) ->
    user(User) andalso bytes(Passphrase, 1, ?ERX_LOGIN_PASSPHRASE_MAX) andalso bytes(Peer, 0, ?ERX_LOGIN_PEER_MAX);
in_bounds(_Request) -> false.

bytes(B, Min, Max) -> is_binary(B) andalso byte_size(B) >= Min andalso byte_size(B) =< Max.

user(User) -> erx_ident:new(User) =/= {error, bad_identifier}.

%% A request: a third within the interface, the rest mutated or random.
request() ->
    Good = case rand:uniform(4) of
               1 -> cookie;
               2 -> {key_ok, name(), bin(1, ?ERX_LOGIN_BLOB_MAX)};
               3 -> {login_key, name(), bin(1, ?ERX_LOGIN_EXCHANGE_MAX), bin(1, ?ERX_LOGIN_BLOB_MAX),
                     bin(1, ?ERX_LOGIN_BLOB_MAX), bin(1, ?ERX_LOGIN_BLOB_MAX), bin(0, ?ERX_LOGIN_PEER_MAX)};
               4 -> {login_passphrase, name(), bin(1, ?ERX_LOGIN_PASSPHRASE_MAX), bin(0, ?ERX_LOGIN_PEER_MAX)}
           end,
    case rand:uniform(9) of
        N when N =< 3 -> Good;
        4 -> mutate(Good, fun(_) -> bin(?ERX_LOGIN_EXCHANGE_MAX + 1, ?ERX_LOGIN_EXCHANGE_MAX + 1) end);
        5 -> mutate(Good, fun(B) when is_binary(B) -> <<B/binary, (edge_byte())>>; (T) -> T end);
        6 -> mutate(Good, fun(_) -> other_type() end);
        7 -> mutate(Good, fun(_) -> <<>> end);
        8 when is_tuple(Good) -> list_to_tuple(lists:droplast(tuple_to_list(Good)));
        8 -> {cookie};
        9 -> other_type()
    end.

%% Good with one argument after the operation replaced by Change of it.
mutate(cookie, _Change) -> {cookie, <<>>};
mutate(Good, Change) ->
    At = 1 + rand:uniform(tuple_size(Good) - 1),
    setelement(At, Good, Change(element(At, Good))).

%% A name at and near its bounds, now and then with a byte outside the alphabet.
name() ->
    Size = case rand:uniform(3) of
               1 -> 1;
               2 -> ?IDENT_EDGE;
               3 -> rand:uniform(?IDENT_EDGE)
           end,
    Alphabet = <<"abcdefghijklmnopqrstuvwxyz0123456789_-">>,
    Rest = << <<(binary:at(Alphabet, rand:uniform(byte_size(Alphabet)) - 1))>> || _ <- lists:seq(2, Size) >>,
    <<($a + rand:uniform(26) - 1), Rest/binary>>.

bin(Min, Max) ->
    Size = case rand:uniform(3) of
               1 -> Min;
               2 -> Max;
               3 -> Min + rand:uniform(Max - Min + 1) - 1
           end,
    rand:bytes(Size).

edge_byte() -> lists:nth(rand:uniform(6), [$A, $-, $., 0, 255, $Z]).

other_type() ->
    lists:nth(rand:uniform(6), [42, an_atom, "list", {tuple}, [<<"x">>], make_ref()]).
