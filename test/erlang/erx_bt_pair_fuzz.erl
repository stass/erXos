%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the reader of the control tree's lines (docs/design-bluetooth.md,
%% "The client", "Fuzz targets"): erx_bt_pair:next/1 and bonds/1 over a stub file
%% (erx_bt_pair_stub) that splits a stream into reads at fuzzer-chosen points, and
%% parse/1 and parse_bond/1 on every line next/1 yields. The seeds come first: every kind
%% of line split inside each line and at each newline's neighbours, and unterminated
%% streams past bt_pair_line_max. A round's stream is pieces of window lines, bond
%% records, mutations of them, random bytes and runs at the bound. Whatever arrives,
%% nothing raises and no atom is made; next/1 yields what a model that scans the whole
%% stream at once says, whatever the split, and asks no read for more than the bound;
%% bonds/1 agrees with the same model; and a line parse/1 or parse_bond/1 accepts is the
%% one its formatter makes of the term. The seed comes from make check-fuzz.

-module(erx_bt_pair_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 5000).
-define(MAX, ?ERX_BT_PAIR_LINE_MAX).

run([Seed]) ->
    rand:seed(exsss, {20, 28, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Seeded = [round_of(Stream, Plan) || {Stream, Plan} <- seeds()],
    Accepted = lists:sum(Seeded) + lists:sum([round_of(stream(), plan()) || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?ROUNDS div 2 of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS + length(Seeded), Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

seeds() ->
    Every = iolist_to_binary([[erx_bt_pair:format(Line), $\n] || Line <- every_line()]),
    Bonds = iolist_to_binary([[erx_bt_pair:format_bond(bond()), $\n] || _ <- lists:seq(1, 9)]),
    Unterminated = [binary:copy(<<"x">>, ?MAX + 1), binary:copy(<<"x">>, 1 bsl 20),
                    <<"waiting\n", (binary:copy(<<"y">>, ?MAX + 2))/binary>>],
    [{Every, Plan} || Plan <- [1, 2, 3, all]] ++ [{Bonds, Plan} || Plan <- [1, all]]
    ++ [{Stream, Plan} || Stream <- Unterminated, Plan <- [1, all]].

%% One round: the number of lines parse/1 or parse_bond/1 accepted.
round_of(Stream, Plan) ->
    Atoms = erlang:system_info(atom_count),
    Expected = model(Stream),
    Stub = erx_bt_pair_stub:start(Stream, Plan),
    Got = read_all(erx_bt_pair:reader(Stub)),
    Got =:= Expected orelse error({disagrees_with_model, Stream, Plan, Got, Expected}),
    [error({read_past_bound, Stream, Plan, Count}) || Count <- erx_bt_pair_stub:asked(Stub), Count > ?MAX + 1],
    stop(Stub),
    Listed = erx_bt_pair_stub:start(Stream, Plan),
    Bonds = erx_bt_pair:bonds(Listed),
    stop(Listed),
    Bonds =:= model_bonds(Expected, []) orelse error({bonds_disagree_with_model, Stream, Bonds}),
    Accepted = lists:sum([accepted(Line) || Line <- Got, is_binary(Line)]),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Stream}),
    Accepted.

%% A line parse/1 or parse_bond/1 accepts must be the formatter's own text of the term.
accepted(Line) ->
    case {erx_bt_pair:parse(Line), erx_bt_pair:parse_bond(Line)} of
        {invalid, invalid} -> 0;
        {Term, invalid} -> erx_bt_pair:format(Term) =:= Line orelse error({not_canonical, Line, Term}), 1;
        {invalid, Bond} -> erx_bt_pair:format_bond(Bond) =:= Line orelse error({not_canonical, Line, Bond}), 1;
        Both -> error({both_grammars, Line, Both})
    end.

read_all(Reader) ->
    case erx_bt_pair:next(Reader) of
        {line, Line, Next} -> [Line | read_all(Next)];
        Ended -> [Ended]
    end.

stop(Stub) ->
    unlink(Stub),
    exit(Stub, kill).

%% What next/1 yields over Stream, from the whole stream at once: a line wherever a
%% newline falls within the bound's octets after its start.
model(Stream) ->
    case binary:match(Stream, <<"\n">>, [{scope, {0, min(byte_size(Stream), ?MAX + 1)}}]) of
        {At, 1} ->
            <<Line:At/binary, $\n, Rest/binary>> = Stream,
            [Line | model(Rest)];
        nomatch when byte_size(Stream) > ?MAX -> [overlong];
        nomatch when Stream =:= <<>> -> [eof];
        nomatch -> [{error, truncated}]
    end.

model_bonds([Line | _], Bonds) when is_binary(Line), length(Bonds) =:= ?ERX_BT_BONDS_MAX -> overlong;
model_bonds([Line | Rest], Bonds) when is_binary(Line) ->
    case erx_bt_pair:parse_bond(Line) of
        invalid -> invalid;
        Bond -> model_bonds(Rest, [Bond | Bonds])
    end;
model_bonds([eof], Bonds) -> {ok, lists:reverse(Bonds)};
model_bonds([Ended], _) -> Ended.

%% Generators ------------------------------------------------------------------

stream() ->
    iolist_to_binary([piece() || _ <- lists:seq(1, rand:uniform(7) - 1)]).

piece() ->
    case rand:uniform(7) of
        1 -> [erx_bt_pair:format(line()), $\n];
        2 -> [erx_bt_pair:format_bond(bond()), $\n];
        3 -> [mutated(erx_bt_pair:format(line())), $\n];
        4 -> [mutated(erx_bt_pair:format_bond(bond())), $\n];
        5 -> rand:bytes(rand:uniform(40) - 1);
        6 -> [binary:copy(<<"x">>, ?MAX - 2 + rand:uniform(4)), lists:nth(rand:uniform(2), [<<>>, <<"\n">>])];
        7 -> erx_bt_pair:format(line())
    end.

%% Each read at most all it asks, a fixed count, or counts chosen read by read.
plan() ->
    case rand:uniform(3) of
        1 -> all;
        2 -> rand:uniform(?MAX + 2);
        3 -> [rand:uniform(?MAX + 2) || _ <- lists:seq(1, rand:uniform(8))]
    end.

every_line() ->
    [{wait, 1}, waiting, {passkey, <<"000000">>, address()}, {bonded, bond()},
     {failed, address(), secure_connections_required}, {closed, timeout}].

line() ->
    case rand:uniform(6) of
        1 -> {wait, rand:uniform(64)};
        2 -> waiting;
        3 -> {passkey, iolist_to_binary(io_lib:format("~6..0B", [rand:uniform(1000000) - 1])), address()};
        4 -> {bonded, bond()};
        5 -> {failed, address(), lists:nth(rand:uniform(4), [confirm, peer, bonds_full, secure_connections_required])};
        6 -> {closed, timeout}
    end.

bond() ->
    #{id => binary:encode_hex(rand:bytes(16), lowercase), address => address(),
      type => lists:nth(rand:uniform(2), [public, random]),
      level => lists:nth(rand:uniform(2), [authenticated, unauthenticated])}.

address() -> rand:bytes(6).

mutated(<<>>) ->
    <<>>;
mutated(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, _:8, After/binary>> = Bytes,
    <<Before/binary, (rand:uniform(256) - 1):8, After/binary>>.
