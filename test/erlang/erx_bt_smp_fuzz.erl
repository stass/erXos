%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the Security Manager channel (docs/design-bluetooth.md, "Fuzz
%% targets"): erx_smp:decode/1, the reader of every PDU a radio peer sends on it, and
%% erx_smp_core:step/2, which takes what it decodes. A round writes a PDU from the
%% layouts of Core 6.3 Vol 3 Part H, section 3, used as written, cut, lengthened, given
%% a random code or replaced by random bytes, decodes it, and hands the result to a
%% responder that this module also gives the window's verdicts, encryption, timeouts and
%% public keys on the curve, off it, the debug key and erXos's own. Whatever arrives,
%% neither makes an atom or raises, and:
%%
%% * a PDU written from a term decodes to that term, its multi-octet fields reversed
%%   from the wire's least significant octet first (1.2.1);
%% * any PDU decode/1 gives encodes back to the input byte for byte, so every field is
%%   read and none is read past its layout;
%% * `{invalid, Code}` exactly for a known code with another length, `{reserved, Code}`
%%   exactly for a code this module does not know, `empty` exactly for no octets;
%% * every PDU the responder sends encodes and decodes back to itself.
%%
%% Every layout is written out here, apart from erx_smp's code, so a layout misread
%% there disagrees with this module. The seed comes from make check-fuzz.

-module(erx_bt_smp_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
%% Each command's code and the length of its Data (3.3, Table 3.3; 3.5 and 3.6).
-define(LAYOUTS, [{16#01, 6}, {16#02, 6}, {16#03, 16}, {16#04, 16}, {16#05, 1}, {16#06, 16}, {16#07, 10},
                  {16#08, 16}, {16#09, 7}, {16#0B, 1}, {16#0C, 64}, {16#0D, 16}, {16#0E, 1}]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    erx_smp_crypto:on_curve(erx_smp_crypto:debug_key()),
    Atoms = erlang:system_info(atom_count),
    Fresh = fresh(),
    _ = lists:foldl(fun(_, Core) -> round(Core, Fresh) end, core(), lists:seq(1, ?ROUNDS)),
    Atoms =:= erlang:system_info(atom_count) orelse verdict({atoms_made, erlang:system_info(atom_count) - Atoms}),
    io:format("fuzz: ~b rounds ok, seed ~s~n", [?ROUNDS, Seed]).

core() -> erx_smp_core:new(#{central => {random, <<1:48>>}, peripheral => {public, <<2:48>>}}).

fresh() ->
    {<<4, X:32/binary, Y:32/binary>>, Private} = crypto:generate_key(ecdh, secp256r1, crypto:hash(sha256, <<1>>)),
    #{private => Private, public => {X, Y}, nonces => [crypto:hash(md5, <<I>>) || I <- lists:seq(1, 20)],
      passkey => 123456}.

round(Core, Fresh) ->
    %% A responder that has timed out ignores everything, so it starts again.
    Current = case rand:uniform(50) of 1 -> core(); _ -> Core end,
    case rand:uniform(11) of
        5 -> pairing(Fresh);
        N -> element(2, step(input(N, Fresh), Current))
    end.

input(1, Fresh) ->
    %% A verdict or a withdrawal for one of the first requests, current or late.
    {admission, rand:uniform(4), lists:nth(rand:uniform(5), [closed, waiting, bonded, {open, display, Fresh},
                                                             {open, nodisplay, Fresh}])};
input(2, _Fresh) -> lists:nth(rand:uniform(3), [encrypted, timeout, {withdraw, rand:uniform(4)}]);
input(3, Fresh) -> {pdu, {pairing_public_key, key(Fresh)}};
input(4, _Fresh) -> {pdu, {pairing_request, written_request()}};
input(_, _Fresh) -> {pdu, decoded(input())}.

%% A pairing as far as the phone's public key, which the step that takes the request
%% and the window's opening of it make possible: a fresh responder, a request, the
%% window open under the request's own tag, then a public key of key/1's kinds. Chance
%% inputs reach the key's checks only when they happen to be in this order.
pairing(Fresh) ->
    {Asked, Requested} = step({pdu, {pairing_request, written_request()}}, core()),
    Mode = lists:nth(rand:uniform(2), [display, nodisplay]),
    Opened = case [Tag || {admit, Tag} <- Asked] of
                 [Tag] -> element(2, step({admission, Tag, {open, Mode, Fresh}}, Requested));
                 [] -> Requested
             end,
    element(2, step({pdu, {pairing_public_key, key(Fresh)}}, Opened)).

step(Input, Core) ->
    {Actions, Next} = try erx_smp_core:step(Input, Core)
                      catch Class:Reason -> verdict({core_raised, Input, Class, Reason})
                      end,
    [erx_smp:decode(erx_smp:encode(Pdu)) =:= Pdu orelse verdict({sent_wrongly, Pdu}) || {send, Pdu} <- Actions],
    {Actions, Next}.

%% A public key: random coordinates, a point moved off the curve, the debug key,
%% erXos's own, or a fresh one on the curve.
key(#{public := Own}) ->
    case rand:uniform(5) of
        1 -> {rand:bytes(32), rand:bytes(32)};
        2 -> {X, <<Y:256>>} = generated(), {X, <<(Y + 1):256>>};
        3 -> erx_smp_crypto:debug_key();
        4 -> Own;
        5 -> generated()
    end.

generated() ->
    {<<4, X:32/binary, Y:32/binary>>, _} = crypto:generate_key(ecdh, secp256r1),
    {X, Y}.

%% An honest-looking request: Secure Connections, bonding and the identity key, with a
%% random IO capability and key size, so the responder gets past the feature exchange.
written_request() ->
    #{io => rand:uniform(6) - 1, oob => 0, auth => 16#0D, max_key => 15 + rand:uniform(2),
      initiator_keys => 16#02, responder_keys => 0}.

%% Bytes for the channel, checked against what decode/1 makes of them.
input() ->
    case rand:uniform(5) of
        1 -> rand:bytes(rand:uniform(70) - 1);
        2 -> written();
        3 -> cut(written());
        4 -> <<(written())/binary, (rand:bytes(rand:uniform(4)))/binary>>;
        5 -> <<(rand:uniform(256) - 1), (rand:bytes(rand:uniform(65) - 1))/binary>>
    end.

cut(Pdu) -> binary:part(Pdu, 0, rand:uniform(byte_size(Pdu)) - 1).

%% A PDU of a random known code written with its term, which decode/1 must give back.
written() ->
    {Code, Length} = lists:nth(rand:uniform(length(?LAYOUTS)), ?LAYOUTS),
    Data = rand:bytes(Length),
    Pdu = <<Code, Data/binary>>,
    Expected = term(Code, Data),
    Expected =:= erx_smp:decode(Pdu) orelse verdict({decoded_wrongly, Pdu, Expected, erx_smp:decode(Pdu)}),
    Pdu.

term(16#01, <<Io, Oob, Auth, Max, I, R>>) ->
    {pairing_request, #{io => Io, oob => Oob, auth => Auth, max_key => Max, initiator_keys => I, responder_keys => R}};
term(16#02, Data) -> {pairing_request, Features} = term(16#01, Data), {pairing_response, Features};
term(16#03, Data) -> {pairing_confirm, rev(Data)};
term(16#04, Data) -> {pairing_random, rev(Data)};
term(16#05, <<Reason>>) -> {pairing_failed, Reason};
term(16#06, Data) -> {encryption_information, rev(Data)};
term(16#07, <<Ediv:2/binary, Rand:8/binary>>) -> {central_identification, rev(Ediv), rev(Rand)};
term(16#08, Data) -> {identity_information, rev(Data)};
term(16#09, <<Type, Address:6/binary>>) -> {identity_address_information, Type, rev(Address)};
term(16#0B, <<Auth>>) -> {security_request, Auth};
term(16#0C, <<X:32/binary, Y:32/binary>>) -> {pairing_public_key, {rev(X), rev(Y)}};
term(16#0D, Data) -> {pairing_dhkey_check, rev(Data)};
term(16#0E, <<Type>>) -> {pairing_keypress_notification, Type}.

rev(Bytes) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).

%% What decode/1 makes of any bytes, checked against the layouts.
decoded(Bytes) ->
    Decoded = try erx_smp:decode(Bytes)
              catch Class:Reason -> verdict({decode_raised, Bytes, Class, Reason})
              end,
    Known = case Bytes of
                <<>> -> empty;
                <<First, Data/binary>> -> {lists:keyfind(First, 1, ?LAYOUTS), First, byte_size(Data)}
            end,
    case {Known, Decoded} of
        {empty, empty} -> ok;
        {{false, Code, _}, {reserved, Code}} -> ok;
        {{{Code, Length}, Code, Size}, {invalid, Code}} when Size =/= Length -> ok;
        {{{Code, Length}, Code, Length}, Pdu} when is_tuple(Pdu), element(1, Pdu) =/= invalid,
                                                   element(1, Pdu) =/= reserved ->
            erx_smp:encode(Pdu) =:= Bytes orelse verdict({decoded_wrongly, Bytes, Pdu});
        _ -> verdict({length_disagrees, Bytes, Decoded})
    end,
    Decoded.

verdict(Term) ->
    io:format("~p~n", [Term]),
    halt(1).
