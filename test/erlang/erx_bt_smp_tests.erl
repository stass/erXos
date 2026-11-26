%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The Security Manager's cores (docs/design-bluetooth.md, "Secure Connections only"
%% and "Host tests of the cores"): erx_smp_crypto against the sample data of Core 6.3
%% Vol 3 Part H, Appendix D, each vector cited; erx_smp's layouts; and erx_smp_core,
%% each refusal by itself and then explored breadth first over every input order from
%% a fixed set, with an honest phone's values and wrong ones, checking its invariants
%% on every transition.

-module(erx_bt_smp_tests).
-include_lib("eunit/include/eunit.hrl").

%% A hex string of the specification's sample data, spaces allowed.
h(Hex) -> binary:decode_hex(iolist_to_binary(string:replace(Hex, " ", "", all))).

%% --- erx_smp_crypto: Appendix D ---------------------------------------------------------

-define(CMAC_KEY, "2b7e1516 28aed2a6 abf71588 09cf4f3c").
-define(M64, "6bc1bee2 2e409f96 e93d7e11 7393172a ae2d8a57 1e03ac9c 9eb76fac 45af8e51"
             "30c81c46 a35ce411 e5fbc119 1a0a52ef f69f2445 df4f9b17 ad2b417b e66c3710").

%% D.1, RFC 4493's four examples, and its AES_128(key, 0) as e.
aes_cmac_matches_appendix_d1_test() ->
    Key = h(?CMAC_KEY),
    M = h(?M64),
    ?assertEqual(h("7df76b0c 1ab899b3 3e42f047 b91b546f"), erx_smp_crypto:e(Key, <<0:128>>)),
    ?assertEqual(h("bb1d6929 e9593728 7fa37d12 9b756746"), erx_smp_crypto:aes_cmac(Key, <<>>)),
    ?assertEqual(h("070a16b4 6b4d4144 f79bdd9d d04a287c"), erx_smp_crypto:aes_cmac(Key, binary:part(M, 0, 16))),
    ?assertEqual(h("dfa66747 de9ae630 30ca3261 1497c827"), erx_smp_crypto:aes_cmac(Key, binary:part(M, 0, 40))),
    ?assertEqual(h("51f0bebf 7e3b9d92 fc497417 79363cfe"), erx_smp_crypto:aes_cmac(Key, M)).

-define(U, "20b003d2 f297be2c 5e2c83a7 e9f9a5b9 eff49111 acf4fddb cc030148 0e359de6").
-define(V, "55188b3d 32f6bb9a 900afcfb eed4e72a 59cb9ac2 f19d7cfb 6b4fdd49 f47fc5fd").
-define(N1, "d5cb8454 d177733e ffffb2ec 712baeab").
-define(N2, "a6e8e7cc 25a75f6e 216583f7 ff3dc4cf").
-define(MACKEY, "2965f176 a1084a02 fd3f6a20 ce636e20").
%% D.3's A1 and A2, 56 bits each with a top octet of zero: public addresses.
-define(A1, {public, h("561237 37bfce")}).
-define(A2, {public, h("a71370 2dcfc1")}).

%% D.2.
f4_matches_appendix_d2_test() ->
    ?assertEqual(h("f2c916f1 07a9bd1c f1eda1be a974872d"), erx_smp_crypto:f4(h(?U), h(?V), h(?N1), 0)).

%% D.3: the LTK (Counter = 1) and the MacKey (Counter = 0).
f5_matches_appendix_d3_test() ->
    W = h("ec0234a3 57c8ad05 341010a6 0a397d9b 99796b13 b4f866f1 868d34f3 73bfa698"),
    ?assertEqual({h(?MACKEY), h("69867911 69d7cd23 980522b5 94750a38")},
                 erx_smp_crypto:f5(W, h(?N1), h(?N2), ?A1, ?A2)).

%% D.4.
f6_matches_appendix_d4_test() ->
    ?assertEqual(h("e3c47398 9cd0e8c5 d26c0b09 da958f61"),
                 erx_smp_crypto:f6(h(?MACKEY), h(?N1), h(?N2), h("12a3343b b453bb54 08da42d2 0c2d0fc8"),
                                   h("010102"), ?A1, ?A2)).

%% D.7.
ah_matches_appendix_d7_test() ->
    ?assertEqual(h("0dfbaa"), erx_smp_crypto:ah(h("ec0234a3 57c8ad05 341010a6 0a397d9b"), h("708194"))).

%% The debug key (2.3.5.6.1) is on P-256, as is a fresh key; a point moved by one in Y
%% is not, nor is a coordinate of p or more.
curve_check_test() ->
    {X, Y} = Debug = erx_smp_crypto:debug_key(),
    ?assertEqual(h(?U), X),
    ?assert(erx_smp_crypto:on_curve(Debug)),
    ?assert(erx_smp_crypto:on_curve(maps:get(public, erx_smp_crypto:fresh()))),
    ?assertNot(erx_smp_crypto:on_curve({X, plus_one(Y)})),
    {{prime_field, P}, _, _, _, _} = crypto:ec_curve(secp256r1),
    ?assertNot(erx_smp_crypto:on_curve({P, Y})),
    ?assertNot(erx_smp_crypto:on_curve({X, P})).

plus_one(<<N:256>>) -> <<(N + 1):256>>.

%% Two fresh key pairs agree on their DHKey; each pairing's values are fresh.
dhkey_agrees_test() ->
    #{private := A, public := PA, nonces := NA, passkey := KA} = erx_smp_crypto:fresh(),
    #{private := B, public := PB, nonces := NB} = erx_smp_crypto:fresh(),
    ?assertEqual(erx_smp_crypto:dhkey(A, PB), erx_smp_crypto:dhkey(B, PA)),
    ?assertNotEqual(NA, NB),
    ?assertEqual(20, length(NA)),
    ?assert(KA >= 0 andalso KA =< 999999).

%% --- erx_smp: the layouts of section 3 ---------------------------------------------------

%% A Pairing Request as Figure 3.2 lays it out, and a public key least significant octet
%% first (1.2.1, Figure 3.8).
codec_layout_test() ->
    ?assertEqual({pairing_request, #{io => 4, oob => 0, auth => 16#2D, max_key => 16, initiator_keys => 16#0B,
                                     responder_keys => 16#0B}},
                 erx_smp:decode(<<16#01, 4, 0, 16#2D, 16, 16#0B, 16#0B>>)),
    ?assertEqual(#{bonding => 1, mitm => true, sc => true, keypress => false, ct2 => true}, erx_smp:auth(16#2D)),
    ?assertEqual(#{enc => true, id => true, link => true}, erx_smp:keys(16#0B)),
    X = list_to_binary(lists:seq(1, 32)),
    Y = list_to_binary(lists:seq(33, 64)),
    Wire = <<16#0C, (list_to_binary(lists:reverse(lists:seq(1, 32))))/binary,
             (list_to_binary(lists:reverse(lists:seq(33, 64))))/binary>>,
    ?assertEqual({pairing_public_key, {X, Y}}, erx_smp:decode(Wire)),
    ?assertEqual(Wire, erx_smp:encode({pairing_public_key, {X, Y}})).

%% Every command with its exact length round-trips, one octet more or less is invalid,
%% and the reserved codes and an empty PDU are named so.
codec_lengths_test() ->
    Lengths = [{16#01, 6}, {16#02, 6}, {16#03, 16}, {16#04, 16}, {16#05, 1}, {16#06, 16}, {16#07, 10}, {16#08, 16},
               {16#09, 7}, {16#0B, 1}, {16#0C, 64}, {16#0D, 16}, {16#0E, 1}],
    [begin
         Pdu = <<Code, (binary:copy(<<16#A5>>, Length))/binary>>,
         Decoded = erx_smp:decode(Pdu),
         ?assertEqual(Pdu, erx_smp:encode(Decoded)),
         ?assertEqual({invalid, Code}, erx_smp:decode(<<Pdu/binary, 0>>)),
         ?assertEqual({invalid, Code}, erx_smp:decode(binary:part(Pdu, 0, Length)))
     end || {Code, Length} <- Lengths],
    [?assertEqual({reserved, Code}, erx_smp:decode(<<Code, 1, 2, 3>>)) || Code <- [0, 16#0A, 16#0F, 16#FF]],
    ?assertEqual(empty, erx_smp:decode(<<>>)).

%% --- erx_smp_core -------------------------------------------------------------------------

-define(CENTRAL, {random, h("c0ffee123456")}).
-define(PERIPHERAL, {random, h("d1e2f3a4b5c6")}).
-define(PASSKEY, 314159).
%% The passkey's bit for each round of Passkey Entry, round 0 first, written out rather
%% than computed so the honest phone does not share erx_smp_core's rule. Figure 2.4's
%% "ra = ra1 | ra2 | ... ra20" leaves the order open; two independent stacks take
%% round i's bit as bit i of the passkey, the least significant first: Bumble v0.0.237,
%% bumble/smp.py lines 993, 1682 and 1711, and NimBLE 648fc0213fb7, nimble/host/src/ble_sm_sc.c
%% lines 246 to 248, its tk the passkey least significant octet first (ble_sm.c 3024).
%% 314159 is 16#4CB2F.
-define(PASSKEY_BITS, [1, 1, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]).
-define(REQUESTS, 2).

%% Fixed key pairs and nonces, so the exploration is deterministic: erXos's fresh
%% values and the honest phone's.
key(Seed) ->
    {<<4, X:32/binary, Y:32/binary>>, Private} =
        crypto:generate_key(ecdh, secp256r1, crypto:hash(sha256, <<Seed>>)),
    {Private, {X, Y}}.

nonces(Seed) -> [crypto:hash(md5, <<Seed, I>>) || I <- lists:seq(1, 20)].

fresh() ->
    {Private, Public} = key(1),
    #{private => Private, public => Public, nonces => nonces(1), passkey => ?PASSKEY}.

core() -> erx_smp_core:new(#{central => ?CENTRAL, peripheral => ?PERIPHERAL}).

%% The honest phone's requests: a keyboard for Passkey Entry, none for Just Works, both
%% with Secure Connections, MITM, bonding and every key offered.
request(Io) ->
    #{io => Io, oob => 0, auth => erx_smp:auth_octet(#{bonding => 1, mitm => true, sc => true, keypress => false,
                                                        ct2 => true}),
      max_key => 16, initiator_keys => 16#0B, responder_keys => 16#0B}.

-define(KEYBOARD, request(4)).
-define(NO_IO, request(3)).

%% The honest phone: what it sends next in each phase of the core, given what it asked
%% and erXos's values, computed independently with erx_smp_crypto.
honest(Request, Mode) ->
    {PhonePrivate, PhonePublic} = key(2),
    {_, Own} = key(1),
    Na = nonces(2),
    Method = case Mode of display -> passkey; nodisplay -> just_works end,
    Z = fun(Round) when Method =:= passkey -> 16#80 bor lists:nth(Round + 1, ?PASSKEY_BITS);
           (_) -> 0
        end,
    Dh = erx_smp_crypto:dhkey(PhonePrivate, Own),
    Rounds = case Method of passkey -> 20; just_works -> 1 end,
    NaLast = lists:nth(Rounds, Na),
    NbLast = lists:nth(Rounds, nonces(1)),
    {MacKey, Ltk} = erx_smp_crypto:f5(Dh, NaLast, NbLast, ?CENTRAL, ?PERIPHERAL),
    R = case Method of passkey -> <<?PASSKEY:128>>; just_works -> <<0:128>> end,
    #{auth := Auth, oob := Oob, io := Io} = Request,
    Ea = erx_smp_crypto:f6(MacKey, NaLast, NbLast, R, <<Auth, Oob, Io>>, ?CENTRAL, ?PERIPHERAL),
    #{public => PhonePublic, ltk => Ltk, ea => Ea,
      confirm => fun(Round) -> erx_smp_crypto:f4(element(1, PhonePublic), element(1, Own),
                                                 lists:nth(Round + 1, Na), Z(Round)) end,
      nonce => fun(Round) -> lists:nth(Round + 1, Na) end,
      level => case Method of passkey -> authenticated; just_works -> unauthenticated end}.

%% Feeds inputs in order; returns every action and the last state.
run(Inputs) -> run(Inputs, core()).
run(Inputs, State) ->
    lists:foldl(fun(Input, {Actions, S}) ->
                        {More, Next} = erx_smp_core:step(Input, S),
                        {Actions ++ More, Next}
                end, {[], State}, Inputs).

%% The window's verdict on the link's first Pairing Request.
open(Mode) -> {admission, 1, {open, Mode, fresh()}}.

%% The honest pairing, input by input, to the bond.
honest_inputs(Request, Mode) ->
    #{public := Public, confirm := Confirm, nonce := Nonce, ea := Ea} = honest(Request, Mode),
    Rounds = case Mode of display -> lists:seq(0, 19); nodisplay -> [] end,
    Stage1 = case Mode of
                 display -> lists:append([[{pdu, {pairing_confirm, Confirm(I)}}, {pdu, {pairing_random, Nonce(I)}}]
                                          || I <- Rounds]);
                 nodisplay -> [{pdu, {pairing_random, Nonce(0)}}]
             end,
    [{pdu, {pairing_request, Request}}, open(Mode), {pdu, {pairing_public_key, Public}}] ++ Stage1 ++
        [{pdu, {pairing_dhkey_check, Ea}}, encrypted, {pdu, {identity_information, <<7:128>>}},
         {pdu, {identity_address_information, 1, h("c1c2c3c4c5c6")}}].

sent_failure(Actions) -> [Code || {send, {pairing_failed, Code}} <- Actions].
%% The failures a run reports, the window's withdrawal among them as `withdrawn`.
failures(Actions) -> [Reason || {failed, Reason} <- Actions] ++ [withdrawn || withdrawn <- Actions].

passkey_entry_completes_authenticated_test() ->
    {Actions, _} = run(honest_inputs(?KEYBOARD, display)),
    #{ltk := Ltk} = honest(?KEYBOARD, display),
    ?assertEqual([], sent_failure(Actions)),
    ?assert(lists:member({passkey, ?PASSKEY}, Actions)),
    ?assert(lists:member({key, Ltk, authenticated}, Actions)),
    ?assertEqual([{bonded, #{ltk => Ltk, level => authenticated, irk => <<7:128>>,
                             identity => {random, h("c1c2c3c4c5c6")}}}],
                 [A || {bonded, _} = A <- Actions]).

just_works_completes_unauthenticated_test() ->
    {Actions, _} = run(honest_inputs(?NO_IO, nodisplay)),
    #{ltk := Ltk} = honest(?NO_IO, nodisplay),
    ?assertEqual([], sent_failure(Actions)),
    ?assertEqual([], [A || {passkey, _} = A <- Actions]),
    ?assert(lists:member({key, Ltk, unauthenticated}, Actions)),
    ?assertMatch([{bonded, #{level := unauthenticated}}], [A || {bonded, _} = A <- Actions]).

%% The response: 16-octet keys, Secure Connections, the identity key asked of the
%% phone, and no link key in either direction (2.3.5.7).
response_test() ->
    [begin
         {Actions, _} = run([{pdu, {pairing_request, ?KEYBOARD}}, open(Mode)]),
         [#{io := Io, max_key := 16, auth := Auth, initiator_keys := I, responder_keys := R}] =
             [F || {send, {pairing_response, F}} <- Actions],
         ?assertEqual(ExpectedIo, Io),
         ?assertMatch(#{sc := true, bonding := 1, mitm := Mitm}, erx_smp:auth(Auth)),
         ?assertEqual(#{enc => false, id => true, link => false}, erx_smp:keys(I)),
         ?assertEqual(#{enc => false, id => false, link => false}, erx_smp:keys(R))
     end || {Mode, ExpectedIo, Mitm} <- [{display, 0, true}, {nodisplay, 3, false}]].

%% A refusal at the window's verdict or the request.
refused(Request, Verdict) ->
    run([{pdu, {pairing_request, Request}}, {admission, 1, Verdict}]).

window_refusals_test() ->
    {Closed, S1} = refused(?KEYBOARD, closed),
    ?assertEqual({[5], []}, {sent_failure(Closed), failures(Closed)}),
    {Waiting, _} = refused(?KEYBOARD, waiting),
    ?assertEqual({[9], []}, {sent_failure(Waiting), failures(Waiting)}),
    {Bonded, _} = refused(?KEYBOARD, bonded),
    ?assertEqual({[8], [already_bonded]}, {sent_failure(Bonded), failures(Bonded)}),
    %% A refusal that is not a pairing leaves the core idle for the next request.
    {Again, _} = run([{pdu, {pairing_request, ?KEYBOARD}}], S1),
    ?assertEqual([{admit, 2}, timer], Again).

%% A verdict that arrives after its request failed never opens the next request.
stale_verdict_ignored_test() ->
    {_, Second} = run([{pdu, {pairing_request, ?KEYBOARD}}, {pdu, {pairing_failed, 16#08}},
                       {pdu, {pairing_request, ?KEYBOARD}}]),
    ?assertEqual({[], Second}, erx_smp_core:step({admission, 1, {open, display, fresh()}}, Second)),
    {Actions, _} = erx_smp_core:step({admission, 2, {open, display, fresh()}}, Second),
    ?assertMatch([{send, {pairing_response, _}}, timer], Actions).

%% The window's withdrawal fails its own pairing, and only its own.
withdraw_test() ->
    {_, Pairing} = run([{pdu, {pairing_request, ?KEYBOARD}}, open(display)]),
    ?assertEqual({[], Pairing}, erx_smp_core:step({withdraw, 2}, Pairing)),
    {Actions, Idle} = erx_smp_core:step({withdraw, 1}, Pairing),
    ?assertEqual({[8], [withdrawn], false}, {sent_failure(Actions), failures(Actions), lists:member(end_link, Actions)}),
    ?assertMatch({[{admit, 2}, timer], _}, erx_smp_core:step({pdu, {pairing_request, ?KEYBOARD}}, Idle)).

%% A failure after the link has its key, in the third phase, ends the link and the core,
%% whatever fails it: a wrong PDU, the phone's Pairing Failed or the window's withdrawal.
failure_after_key_ends_link_test() ->
    Inputs = honest_inputs(?NO_IO, nodisplay),
    Keyed = lists:takewhile(fun(I) -> I =/= encrypted end, Inputs),
    [begin
         {Actions, Ended} = run(Keyed ++ Rest),
         ?assertEqual({Sent, [Reason]}, {sent_failure(Actions), failures(Actions)}),
         ?assertEqual(end_link, lists:last(Actions)),
         ?assertEqual({[], Ended}, run([{pdu, {pairing_request, ?NO_IO}}], Ended))
     end || {Rest, Sent, Reason} <- [{[{pdu, {pairing_dhkey_check, <<3:128>>}}], [8], unexpected},
                                     {[{pdu, {pairing_failed, 16#08}}], [], {peer, 16#08}},
                                     {[{withdraw, 1}], [8], withdrawn}]].

%% The phone's identity address is public or static random (3.6.5). Any 48 bits make a
%% public address; a static random address has its top two bits set and its other 46
%% neither all zeros nor all ones (Vol 6 Part B, 1.3.2 and 1.3.2.1), so a private
%% address claimed as an identity, or a type that is neither, fails with Invalid
%% Parameters and ends the link.
identity_address_test() ->
    Keyed = lists:takewhile(fun(I) -> I =/= encrypted end, honest_inputs(?NO_IO, nodisplay)),
    {_, Identity} = run(Keyed ++ [encrypted, {pdu, {identity_information, <<7:128>>}}]),
    Claim = fun(Type, Address) -> run([{pdu, {identity_address_information, Type, Address}}], Identity) end,
    [?assertMatch({[{bonded, #{identity := Expected}}, timer_stop], _}, Claim(Type, Address))
     || {Type, Address, Expected} <- [{0, h("01c2c3c4c5c6"), {public, h("01c2c3c4c5c6")}},
                                      {1, h("c1c2c3c4c5c6"), {random, h("c1c2c3c4c5c6")}},
                                      {1, <<2#11:2, 1:46>>, {random, <<2#11:2, 1:46>>}},
                                      {1, <<2#11:2, (1 bsl 46 - 2):46>>, {random, <<2#11:2, (1 bsl 46 - 2):46>>}}]],
    [begin
         {Actions, _} = Claim(Type, Address),
         ?assertEqual({Case, [10], [invalid], end_link},
                      {Case, sent_failure(Actions), failures(Actions), lists:last(Actions)})
     end || {Case, Type, Address} <- [{type_2, 2, h("c1c2c3c4c5c6")},
                                       {non_resolvable_private, 1, h("01c2c3c4c5c6")},
                                       {resolvable_private, 1, h("41c2c3c4c5c6")},
                                       {reserved, 1, h("81c2c3c4c5c6")},
                                       {random_part_zeros, 1, <<2#11:2, 0:46>>},
                                       {random_part_ones, 1, <<2#11:2, (1 bsl 46 - 1):46>>}]].

request_refused(Changes, Mode) ->
    {Actions, _} = refused(maps:merge(?KEYBOARD, Changes), {open, Mode, fresh()}),
    {sent_failure(Actions), failures(Actions)}.

secure_connections_required_test() ->
    Legacy = erx_smp:auth_octet(#{bonding => 1, mitm => true, sc => false, keypress => false, ct2 => false}),
    ?assertEqual({[3], [secure_connections_required]}, request_refused(#{auth => Legacy}, display)).

key_size_test() ->
    [?assertEqual({[6], [key_size]}, request_refused(#{max_key => Size}, display)) || Size <- lists:seq(7, 15)],
    [?assertEqual({[10], [invalid]}, request_refused(#{max_key => Size}, display)) || Size <- [0, 6, 17, 255]].

reserved_values_test() ->
    ?assertEqual({[10], [invalid]}, request_refused(#{io => 5}, display)),
    ?assertEqual({[10], [invalid]}, request_refused(#{oob => 2}, display)).

%% A display window takes Passkey Entry alone: a phone without a keyboard, or one
%% claiming OOB data, cannot make a weaker bond in it.
method_test() ->
    [?assertEqual({[3], [method]}, request_refused(#{io => Io}, display)) || Io <- [0, 1, 3]],
    ?assertEqual({[3], [method]}, request_refused(#{oob => 1}, display)),
    ?assertEqual({[3], [method]}, request_refused(#{oob => 1}, nodisplay)),
    ?assertEqual({[], []}, request_refused(#{io => 2}, display)),
    [?assertEqual({[], []}, request_refused(#{io => Io}, nodisplay)) || Io <- [0, 1, 2, 3, 4]].

bonding_test() ->
    NoBonding = erx_smp:auth_octet(#{bonding => 0, mitm => true, sc => true, keypress => false, ct2 => false}),
    ?assertEqual({[3], [bonding]}, request_refused(#{auth => NoBonding}, display)),
    ?assertEqual({[3], [bonding]}, request_refused(#{initiator_keys => 16#01}, display)).

%% The phone's public key, after an admitted request.
public_key_refused(Key) ->
    {Actions, _} = run([{pdu, {pairing_request, ?KEYBOARD}}, open(display), {pdu, {pairing_public_key, Key}}]),
    {sent_failure(Actions), failures(Actions), [A || {send, {pairing_public_key, _}} = A <- Actions]}.

off_curve_key_fails_dhkey_test() ->
    {X, Y} = maps:get(public, honest(?KEYBOARD, display)),
    ?assertEqual({[11], [dhkey], []}, public_key_refused({X, plus_one(Y)})).

debug_key_fails_invalid_parameters_test() ->
    ?assertEqual({[10], [invalid], []}, public_key_refused(erx_smp_crypto:debug_key())).

%% erXos's own key sent back, or its mirror image with the same X (2.3.5.6.1).
reflected_key_fails_dhkey_test() ->
    {_, {X, <<Y:256>>} = Own} = key(1),
    {{prime_field, <<P:256>>}, _, _, _, _} = crypto:ec_curve(secp256r1),
    ?assertEqual({[11], [dhkey], []}, public_key_refused(Own)),
    ?assertEqual({[11], [dhkey], []}, public_key_refused({X, <<(P - Y):256>>})).

%% A wrong commitment fails at its nonce, in the first round and the last.
wrong_confirm_fails_test() ->
    #{nonce := Nonce} = honest(?KEYBOARD, display),
    Inputs = honest_inputs(?KEYBOARD, display),
    [begin
         Index = 4 + 2 * Round,
         {pdu, {pairing_confirm, Good}} = lists:nth(Index, Inputs),
         <<B, Rest/binary>> = Good,
         Wrong = lists:sublist(Inputs, Index - 1) ++ [{pdu, {pairing_confirm, <<(B bxor 1), Rest/binary>>}},
                                                     {pdu, {pairing_random, Nonce(Round)}}],
         {Actions, _} = run(Wrong),
         ?assertEqual({[4], [confirm]}, {sent_failure(Actions), failures(Actions)}),
         %% erXos's nonce of the failed round is never revealed.
         ?assertEqual(Round, length([R || {send, {pairing_random, R}} <- Actions]))
     end || Round <- [0, 19]].

wrong_dhkey_check_fails_test() ->
    Inputs = honest_inputs(?NO_IO, nodisplay),
    Prefix = lists:takewhile(fun({pdu, {pairing_dhkey_check, _}}) -> false; (_) -> true end, Inputs),
    {Actions, _} = run(Prefix ++ [{pdu, {pairing_dhkey_check, <<1:128>>}}]),
    ?assertEqual({[11], [dhkey]}, {sent_failure(Actions), failures(Actions)}),
    ?assertEqual([], [K || {key, _, _} = K <- Actions]).

%% The phone's keys only once the link is encrypted (2.4.3.2).
identity_before_encryption_fails_test() ->
    Inputs = honest_inputs(?NO_IO, nodisplay),
    Prefix = lists:takewhile(fun(I) -> I =/= encrypted end, Inputs),
    {Actions, _} = run(Prefix ++ [{pdu, {identity_information, <<7:128>>}}]),
    ?assertEqual({[8], [unexpected]}, {sent_failure(Actions), failures(Actions)}).

%% A timeout ends the link and sends nothing; the core then ignores everything (3.4).
timeout_test() ->
    {Actions, Ended} = run([{pdu, {pairing_request, ?KEYBOARD}}, open(display), timeout]),
    ?assertEqual({[], [timeout]}, {sent_failure(Actions), failures(Actions)}),
    ?assert(lists:member(end_link, Actions)),
    ?assertEqual({[], Ended}, run(honest_inputs(?KEYBOARD, display), Ended)).

%% --- the exploration ----------------------------------------------------------------------

%% The requests a phone may send, honest and refused.
requests() ->
    Legacy = erx_smp:auth_octet(#{bonding => 1, mitm => true, sc => false, keypress => false, ct2 => false}),
    [?KEYBOARD, ?NO_IO, (?KEYBOARD)#{max_key => 15}, (?KEYBOARD)#{max_key => 17}, (?KEYBOARD)#{auth => Legacy},
     (?KEYBOARD)#{oob => 1}, (?KEYBOARD)#{initiator_keys => 0}, request(1), request(5)].

%% Inputs tried in every state: the generic ones, and each phase's honest input with
%% wrong ones beside it. Each is tagged with whether it keeps the path honest: a
%% generic public key, commitment, nonce or check value does not; the rest carry no
%% value a pairing's security rests on.
inputs({_State, Context, Tag}) ->
    Generic = [{pdu, P} || P <- [{pairing_confirm, <<1:128>>}, {pairing_random, <<2:128>>},
                                {pairing_dhkey_check, <<3:128>>}, {pairing_failed, 16#08},
                                {pairing_response, ?KEYBOARD}, {security_request, 16#0D},
                                {encryption_information, <<4:128>>}, {central_identification, <<5:16>>, <<6:64>>},
                                {identity_information, <<7:128>>}, {identity_address_information, 1, <<2#11:2, 8:46>>},
                                {pairing_keypress_notification, 1}, {invalid, 16#03}, {reserved, 16#0F}, empty]]
        ++ [encrypted, timeout] ++ [{pdu, {pairing_request, R}} || Tag < ?REQUESTS, R <- requests()]
        ++ [{admission, T, V} || T <- [Tag - 1, Tag],
                                 V <- [closed, waiting, bonded, {open, display, fresh()}, {open, nodisplay, fresh()}]]
        ++ [{withdraw, T} || T <- [Tag - 1, Tag]],
    [{I, not carries_value(I)} || I <- Generic] ++ honest_steps(Context).

carries_value({pdu, {Kind, _}}) ->
    lists:member(Kind, [pairing_public_key, pairing_confirm, pairing_random, pairing_dhkey_check]);
carries_value(_Input) -> false.

%% The honest phone's next input for the phase the context records, and wrong ones.
honest_steps({Request, Mode, Phase}) ->
    #{public := {X, Y} = Public, confirm := Confirm, nonce := Nonce, ea := Ea} = honest(Request, Mode),
    case Phase of
        public_key -> [{{pdu, {pairing_public_key, Public}}, true},
                       {{pdu, {pairing_public_key, {X, plus_one(Y)}}}, false},
                       {{pdu, {pairing_public_key, erx_smp_crypto:debug_key()}}, false},
                       {{pdu, {pairing_public_key, element(2, key(1))}}, false}];
        {confirm, Round} -> [{{pdu, {pairing_confirm, Confirm(Round)}}, true}];
        {random, Round} -> [{{pdu, {pairing_random, Nonce(Round)}}, true}];
        dhkey_check -> [{{pdu, {pairing_dhkey_check, Ea}}, true}];
        encrypting -> [{encrypted, true}];
        identity -> [{{pdu, {identity_information, <<9:128>>}}, true}];
        identity_address -> [{{pdu, {identity_address_information, 0, <<10:48>>}}, true},
                             {{pdu, {identity_address_information, 1, <<10:48>>}}, false},
                             {{pdu, {identity_address_information, 2, <<10:48>>}}, false}];
        _ -> []
    end;
honest_steps(_Context) -> [].

%% The exploration's own record of where the honest phone is, advanced from the
%% actions alone, never from the core's state, which is opaque.
context(_Context, {pdu, {pairing_request, Request}}, [{admit, _}, timer]) -> {admitting, Request};
context(none, _Input, _Actions) -> none;
context(Context, Input, Actions) ->
    case sent_failure(Actions) =/= [] orelse failures(Actions) =/= [] of
        true -> none;
        false -> advanced(Context, Input, Actions)
    end.

advanced({admitting, Request}, {admission, _, {open, Mode, _}}, _Actions) -> {Request, Mode, public_key};
advanced({admitting, _} = Context, _Input, _Actions) -> Context;
advanced({Request, Mode, Phase}, _Input, Actions) -> {Request, Mode, next_phase(Phase, Mode, Actions)}.

next_phase(public_key, display, Actions) -> sent(pairing_public_key, Actions, {confirm, 0}, public_key);
next_phase(public_key, nodisplay, Actions) -> sent(pairing_public_key, Actions, {random, 0}, public_key);
next_phase({confirm, Round}, _Mode, Actions) -> sent(pairing_confirm, Actions, {random, Round}, {confirm, Round});
next_phase({random, Round}, display, Actions) when Round < 19 ->
    sent(pairing_random, Actions, {confirm, Round + 1}, {random, Round});
next_phase({random, Round}, _Mode, Actions) -> sent(pairing_random, Actions, dhkey_check, {random, Round});
next_phase(dhkey_check, _Mode, Actions) -> sent(pairing_dhkey_check, Actions, encrypting, dhkey_check);
next_phase(encrypting, _Mode, Actions) -> case lists:member(timer, Actions) of true -> identity; false -> encrypting end;
next_phase(identity, _Mode, Actions) ->
    case lists:member(timer, Actions) of true -> identity_address; false -> identity end;
next_phase(identity_address, _Mode, Actions) ->
    case [b || {bonded, _} <- Actions] of [_] -> done; [] -> identity_address end;
next_phase(Phase, _Mode, _Actions) -> Phase.

sent(Kind, Actions, Advanced, Stay) ->
    case [x || {send, Pdu} <- Actions, element(1, Pdu) =:= Kind] of
        [_ | _] -> Advanced;
        [] -> Stay
    end.

%% The exploration's own count of the Pairing Requests the core took, from its `admit`.
tag(Tag, Actions) ->
    case [T || {admit, T} <- Actions] of
        [T] -> T;
        [] -> Tag
    end.

%% Breadth first over {core state, context, honest so far, the current request's tag};
%% every transition's actions are checked by invariants/4. The tag grows with each
%% request, so the phone sends at most ?REQUESTS of them on a path, enough for a verdict
%% or a withdrawal of the first to arrive during the second.
explored_core_keeps_its_invariants_test_() ->
    {timeout, 300, fun() ->
        Start = {core(), none, true, 0},
        Count = explore(queue:from_list([Start]), #{Start => true}, 0),
        ?assert(Count > 1000)
    end}.

explore(Queue, Seen, Count) ->
    case queue:out(Queue) of
        {empty, _} -> Count;
        {{value, {State, Context, Honest, Tag}}, Rest} ->
            {Next, Seen1, Count1} =
                lists:foldl(
                  fun({Input, InputHonest}, {Q, S, C}) ->
                          {Actions, State1} = erx_smp_core:step(Input, State),
                          %% An input the core ignores, with no action, taints nothing,
                          %% and a new pairing starts honest.
                          Honest1 = Honest andalso (InputHonest orelse Actions =:= []),
                          invariants(Input, Actions, Context, Honest1),
                          ?assert(not stale(Input, Tag) orelse {Actions, State1} =:= {[], State}),
                          Context1 = context(Context, Input, Actions),
                          Fresh = is_tuple(Context1) andalso element(1, Context1) =:= admitting,
                          Node = {State1, Context1, Honest1 orelse Fresh, tag(Tag, Actions)},
                          case S of
                              #{Node := _} -> {Q, S, C + 1};
                              #{} -> {queue:in(Node, Q), S#{Node => true}, C + 1}
                          end
                  end, {Rest, Seen, Count}, inputs({State, Context, Tag})),
            explore(Next, Seen1, Count1)
    end.

%% Identity Address Information's AddrType octet for a bond's address type (3.6.5).
address_type(public) -> 0;
address_type(random) -> 1.

%% A verdict or a withdrawal for an earlier request, which changes nothing.
stale({admission, T, _}, Tag) -> T =/= Tag;
stale({withdraw, T}, Tag) -> T =/= Tag;
stale(_Input, _Tag) -> false.

%% On every transition: each PDU sent encodes and decodes back to itself; a key and a
%% bond come only from the honest phone, with the honest LTK and the window's level, a
%% bond with the identity address the phone claimed in its type; a
%% failure the core reports is a Pairing Failed sent, except the phone's own and a
%% timeout, which send nothing; and a failure once the link has its key ends the link.
invariants(Input, Actions, Context, Honest) ->
    [?assertEqual(Pdu, erx_smp:decode(erx_smp:encode(Pdu))) || {send, Pdu} <- Actions],
    Keys = [A || {key, _, _} = A <- Actions] ++ [A || {bonded, _} = A <- Actions],
    case Keys of
        [] -> ok;
        _ ->
            {Request, Mode, _} = Context,
            ?assert(Honest),
            #{ltk := Ltk, level := Level} = honest(Request, Mode),
            [?assertMatch({key, Ltk, Level}, K) || {key, _, _} = K <- Keys],
            [?assertMatch({bonded, #{ltk := Ltk, level := Level}}, K) || {bonded, _} = K <- Keys],
            [?assertEqual({pdu, {identity_address_information, address_type(Type), Address}}, Input)
             || {bonded, #{identity := {Type, Address}}} <- Keys],
            ?assert(Mode =:= nodisplay orelse Level =:= authenticated)
    end,
    case failures(Actions) of
        [] -> ok;
        [timeout] -> ?assertEqual({[], timeout}, {sent_failure(Actions), Input});
        [{peer, _}] -> ?assertMatch({[], {pdu, {pairing_failed, _}}}, {sent_failure(Actions), Input});
        [_] -> ?assertMatch([_], sent_failure(Actions))
    end,
    case {failures(Actions), Context} of
        {[_], {_, _, Phase}} when Phase =:= encrypting; Phase =:= identity; Phase =:= identity_address ->
            ?assert(lists:member(end_link, Actions));
        _ -> ok
    end.
