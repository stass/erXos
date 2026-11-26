%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the link's core, erx_bt_link_core (docs/design-bluetooth.md, "Host tests of
%% the cores"): the fixed channels, the one key and its encryption, the handler's and the
%% indication's deadlines, the queue, a pairing through the link to the store's answer,
%% and an exploration of every state a small alphabet reaches within a few steps. Frames
%% and PDUs are written from the numbers of the Core Specification 6.3 (Vol 3 Parts A, F
%% and H; Vol 4 Part E, 7.7.8, 7.7.39 and 7.7.65.5), not from the modules' codes.

-module(erx_bt_link_tests).

-include_lib("eunit/include/eunit.hrl").
-define(GAP, #{name => <<"erxos">>, appearance => 0}).

-define(CENTRAL, {random, <<16#C0, 16#FF, 16#EE, 16#12, 16#34, 16#56>>}).
-define(PERIPHERAL, {random, <<16#D1, 16#E2, 16#F3, 16#A4, 16#B5, 16#C6>>}).
%% The phone's identity address, as a bond keeps it and the pairing's Identity Address
%% Information distributes it (type 1, random), most significant octet first as erx_smp_crypto
%% holds an address; the PDU carries it least significant octet first.
-define(IDENTITY, {random, <<16#C1, 16#C2, 16#C3, 16#C4, 16#C5, 16#C6>>}).
%% Two resolvable private addresses (Vol 6 Part B, 1.3.2.2: the top bits 0b01) of one phone.
-define(RPA1, {random, <<16#4A, 16#01, 16#02, 16#03, 16#04, 16#05>>}).
-define(RPA2, {random, <<16#5B, 16#11, 16#12, 16#13, 16#14, 16#15>>}).
-define(BOND_LTK, <<16#B0:128>>).
%% Two bond ids: the resolved bond's, and the one the store gives a pairing's bond at `kept`.
-define(BOND_ID, <<"00000000000000000000000000000001">>).
-define(KEPT_ID, <<"000000000000000000000000000000a2">>).
-define(SHARE, 2).
-define(ACL_TX_MAX, 27).
-define(QUEUE, 16).                       % bt_notify_queue
-define(DEPTH, 6).

%% ---- fixtures ----

services() ->
    [#{name => svc, uuid => <<16#00, 16#FF>>,
       characteristics => [#{name => open_w, uuid => <<16#01, 16#FF>>, max => 20,
                             access => #{write => open, write_without_response => open}},
                           #{name => enc_w, uuid => <<16#02, 16#FF>>, max => 20, access => #{write => encrypted}},
                           #{name => enc_n, uuid => <<16#03, 16#FF>>, max => 20, access => #{notify => encrypted}},
                           #{name => ind, uuid => <<16#04, 16#FF>>, max => 20, access => #{indicate => open}},
                           #{name => bond_w, uuid => <<16#05, 16#FF>>, max => 20, access => #{write => bonded}}]}].

table() -> erx_gatt_db:build(?GAP, services()).

handle(Char) -> {ok, #{value := Handle}} = erx_gatt_db:characteristic({svc, Char}, table()), Handle.
configuration(Char) -> {ok, #{configuration := Handle}} = erx_gatt_db:characteristic({svc, Char}, table()), Handle.

core() -> core(#{}).
core(Options) ->
    erx_bt_link_core:new(maps:merge(#{table => table(), values => #{{gap, device_name} => <<"erxos">>},
                                      addresses => #{central => ?CENTRAL, peripheral => ?PERIPHERAL},
                                      bond => none, share => ?SHARE, acl_tx_max => ?ACL_TX_MAX, now => 0},
                                    Options)).

bonded(Level) -> core(#{bond => resolved(Level, #{})}).

%% A bond the store resolved the phone's address to, with its kept subscriptions.
resolved(Level, Subscriptions) ->
    #{id => ?BOND_ID, ltk => ?BOND_LTK, level => Level, identity => ?IDENTITY,
      hash => <<0:256>>, subscriptions => Subscriptions}.

%% A basic frame (Part A, 3.1) in one ACL packet, flagged first_flushable (Vol 4 Part E, 5.4.2).
frame(Cid, Payload) -> <<(byte_size(Payload)):16/little, Cid:16/little, Payload/binary>>.
acl(Cid, Payload) -> {acl, 2, frame(Cid, Payload)}.
att(Pdu) -> acl(4, Pdu).
smp(Pdu) -> acl(6, Pdu).

%% ATT PDUs (Part F, 3.4).
read(H) -> <<16#0A, H:16/little>>.
write(H, V) -> <<16#12, H:16/little, V/binary>>.
write_cmd(H, V) -> <<16#52, H:16/little, V/binary>>.
write_rsp() -> <<16#13>>.
confirm() -> <<16#1E>>.
error_rsp(Op, H, Code) -> <<16#01, Op, H:16/little, Code>>.

%% SMP's Pairing Request (Part H, 3.5.1): NoInputNoOutput, no OOB, bonding, MITM, Secure
%% Connections and CT2, a 16-octet key, every key offered.
pairing_request() -> <<16#01, 16#03, 0, 16#2D, 16, 16#0B, 16#0B>>.
pairing_failed(Reason) -> <<16#05, Reason>>.

%% The controller's reports: LE Long Term Key Request with Rand and EDIV (7.7.65.5),
%% Encryption Change with status and Encryption_Enabled (7.7.8), Key Refresh (7.7.39).
ltk_request() -> {le_long_term_key_request, 1, <<0:64>>, 0}.
encryption_on() -> {encryption_change, 0, 1, 1}.

%% Feeds inputs in order at time 0, or `{at, Time, Input}`; returns every action and the core.
run(Inputs) -> run(Inputs, core()).
run(Inputs, Core) ->
    lists:foldl(fun({at, Now, Input}, {Actions, C}) -> step(Input, Now, Actions, C);
                   (Input, {Actions, C}) -> step(Input, 0, Actions, C)
                end, {[], Core}, Inputs).

step(Input, Now, Actions, Core) ->
    {More, Next} = core_step(Input, Now, Core),
    {Actions ++ More, Next}.

%% The core's step as the cases write it: an input given without its role is sent by the
%% owner whose clauses take it; a controller message's step must answer `{hci, taken}`
%% first, which is checked and dropped here; and the controller's packets and Long Term
%% Key answers are read without their `hci` tag. roles_test/0 holds the shapes themselves.
core_step(Input, Now, Core) ->
    Tagged = tagged(Input),
    {Actions, Next} = erx_bt_link_core:step(Tagged, Now, Core),
    {untagged(Tagged, Actions), Next}.

tagged(expired) -> expired;
tagged({Role, _} = Input) when Role =:= hci; Role =:= window; Role =:= registry; Role =:= store -> Input;
tagged(Input) when is_atom(Input) -> {role(Input), Input};
tagged(Input) -> {role(element(1, Input)), Input}.

role(Kind) when Kind =:= admission; Kind =:= withdraw; Kind =:= wait -> window;
role(Kind) when Kind =:= answer; Kind =:= set; Kind =:= notify -> registry;
role(Kind) when Kind =:= kept; Kind =:= forgotten -> store;
role(_Kind) -> hci.

untagged({hci, _}, [{hci, taken} | Actions]) -> untagged(none, Actions);
untagged({hci, _}, Actions) -> error({taken_not_first, Actions});
untagged(_Input, Actions) -> [untag(Action) || Action <- Actions].

untag({hci, taken}) -> error(taken_for_another_role);
untag({hci, {send, Boundary, Data}}) -> {acl, Boundary, Data};
untag({hci, {ltk_reply, _} = Reply}) -> Reply;
untag(Action) -> Action.

%% The frames the link sent, joined from its ACL packets: first_non_flushable starts one.
sent(Actions) ->
    Joined = lists:foldl(fun({acl, 0, Data}, Frames) -> [Data | Frames];
                            ({acl, 1, Data}, [Last | Frames]) -> [<<Last/binary, Data/binary>> | Frames];
                            (_, Frames) -> Frames
                         end, [], Actions),
    [{Cid, Payload} || <<_:16, Cid:16/little, Payload/binary>> <- lists:reverse(Joined)].

on(Cid, Actions) -> [Payload || {C, Payload} <- sent(Actions), C =:= Cid].
registry(Actions) -> [Event || {registry, Event} <- Actions].
window(Actions) -> [Message || {window, Message} <- Actions].
closed(Actions) -> [Reason || {close, Reason} <- Actions].
facts(Core) -> erx_bt_link_core:facts(Core).

%% ---- the channels ----

%% A frame on a channel the link does not serve is dropped and counted, and the link stays.
unknown_channel_counted_test() ->
    {Actions, Core} = run([acl(16#0040, <<1, 2, 3>>), acl(16#0003, <<>>)]),
    ?assertEqual([], Actions),
    ?assertMatch(#{dropped := 2}, facts(Core)).

%% Every split of a frame into ACL packets reassembles to the same frame (Part A, 3.1).
reassembly_at_every_fragment_size_test() ->
    Frame = frame(4, write(handle(open_w), binary:copy(<<"v">>, 20))),
    [begin
         {Actions, _} = run(pieces(Frame, Size)),
         ?assertEqual([{write, 1, {svc, open_w}, binary:copy(<<"v">>, 20)}], registry(Actions))
     end || Size <- lists:seq(1, byte_size(Frame))].

pieces(Frame, Size) when byte_size(Frame) =< Size -> [{acl, 2, Frame}];
pieces(Frame, Size) ->
    <<First:Size/binary, Rest/binary>> = Frame,
    [{acl, 2, First} | [{acl, 1, Piece} || Piece <- chunks(Rest, Size)]].

chunks(<<>>, _Size) -> [];
chunks(Bytes, Size) when byte_size(Bytes) =< Size -> [Bytes];
chunks(Bytes, Size) -> <<Piece:Size/binary, Rest/binary>> = Bytes, [Piece | chunks(Rest, Size)].

%% A continuation without a start, and a frame past its channel's bound, end the link.
malformed_frame_ends_link_test() ->
    ?assertMatch([{l2cap, continuation_without_start}], closed(element(1, run([{acl, 1, <<1, 2>>}])))),
    ?assertMatch([{l2cap, {too_long, 6, 66}}], closed(element(1, run([{acl, 2, <<66:16/little, 6:16/little>>}])))).

%% LE signaling: a command is rejected, "Command not understood" (Part A, 4.1).
signaling_rejects_commands_test() ->
    {Actions, _} = run([acl(5, <<16#12, 7, 8:16/little, 0:64>>)]),
    ?assertEqual([<<16#01, 7, 2:16/little, 0:16/little>>], on(5, Actions)).

%% With the share used and never completed, signaling's answers past bt_notify_queue are
%% dropped and counted.
signaling_answers_dropped_at_full_queue_test() ->
    {Actions, Core} = run([acl(5, <<16#12, I, 8:16/little, 0:64>>) || I <- lists:seq(1, ?SHARE + ?QUEUE + 2)]),
    ?assertEqual([], closed(Actions)),
    ?assertMatch(#{queued := ?QUEUE, refused := 2}, facts(Core)).

%% ---- the ATT bearer through the link ----

%% A phone that sends requests without waiting for the responses, while the controller
%% sends nothing, ends its link once the queue would pass bt_notify_queue and two.
att_request_flood_ends_link_test() ->
    Reads = [att(read(3)) || _ <- lists:seq(1, ?SHARE + ?QUEUE + 3)],
    {Actions, _} = run(lists:droplast(Reads)),
    ?assertEqual([], closed(Actions)),
    {Flooded, _} = run(Reads),
    ?assertEqual([queue_overflow], closed(Flooded)),
    ?assertMatch({close, _}, lists:last(Flooded)).

%% A write the gate allows reaches the registry; the handler's answer is the Write Response.
write_round_trip_test() ->
    {Actions, _} = run([att(write(handle(open_w), <<"w">>)), {answer, 1, ok}]),
    ?assertEqual([{write, 1, {svc, open_w}, <<"w">>}], registry(Actions)),
    ?assertEqual([write_rsp()], on(4, Actions)).

%% A write to an `encrypted` characteristic on a link with no key is Insufficient
%% Authentication; on a bonded link not yet encrypted, Insufficient Encryption; once the
%% controller reports encryption, it reaches the handler.
write_waits_for_encryption_test() ->
    Write = att(write(handle(enc_w), <<"e">>)),
    {NoKey, _} = run([Write]),
    ?assertEqual([error_rsp(16#12, handle(enc_w), 16#05)], on(4, NoKey)),
    {Keyed, _} = run([Write], bonded(unauthenticated)),
    ?assertEqual([error_rsp(16#12, handle(enc_w), 16#0F)], on(4, Keyed)),
    ?assertEqual([], registry(Keyed)),
    {Encrypted, _} = run([ltk_request(), encryption_on(), Write], bonded(unauthenticated)),
    ?assertEqual([{security, #{level => encrypted, bond => ?BOND_ID}},
                  {write, 1, {svc, enc_w}, <<"e">>}],
                 registry(Encrypted)).

%% No answer within 5 s is Unlikely Error, and the late answer changes nothing.
handler_deadline_test() ->
    {Actions, Core} = run([att(write(handle(open_w), <<"w">>))]),
    ?assertEqual(5000, erx_bt_link_core:next_deadline(Core)),
    {Early, Core1} = core_step(expired, 4999, Core),
    ?assertEqual([], Early),
    {Late, Core2} = run([{at, 5000, expired}, {at, 5001, {answer, 1, ok}}], Core1),
    ?assertEqual([], registry(Actions) -- [{write, 1, {svc, open_w}, <<"w">>}]),
    ?assertEqual([error_rsp(16#12, handle(open_w), 16#0E)], on(4, Late)),
    ?assertEqual(infinity, erx_bt_link_core:next_deadline(Core2)).

%% A second request before the first's response ends the link (Part F, 3.3.2); write
%% a write command past bt_write_queue behind a handler's answer ends the link
%% (docs/design-bluetooth.md, "What a radio peer can make the domain spend").
one_request_and_command_queue_test() ->
    {Two, _} = run([att(write(handle(open_w), <<"a">>)), att(read(3))]),
    ?assertMatch([{att, request_outstanding}], closed(Two)),
    Commands = [att(write_cmd(handle(open_w), <<I>>)) || I <- lists:seq(0, 17)],
    {Queued, _} = run(lists:droplast(Commands)),
    ?assertEqual([], closed(Queued)),
    {Overflow, _} = run(Commands),
    ?assertEqual([{att, write_queue_full}], closed(Overflow)).

%% ---- notifications ----

%% The gate decides before a notification leaves; the caller hears why.
notification_through_gate_test() ->
    Subscribe = att(write(configuration(enc_n), <<1, 0>>)),
    Notify = {notify, caller, notify, {svc, enc_n}, <<"n">>},
    {Refused, _} = run([Notify]),
    ?assertEqual([{reply, caller, {error, insufficient_security}}], [A || {reply, _, _} = A <- Refused]),
    {Sent, _} = run([ltk_request(), encryption_on(), Subscribe, {kept, {ok, ?KEPT_ID}}, Notify], bonded(unauthenticated)),
    ?assertEqual([{reply, caller, ok}], [A || {reply, _, _} = A <- Sent]),
    ?assertEqual([write_rsp(), <<16#1B, (handle(enc_n)):16/little, "n">>], on(4, Sent)).

%% With the share used and never completed, the queue fills to bt_notify_queue and the
%% next notification is `busy`; completions hand the queue over.
notification_queue_bound_test() ->
    Inputs = [ltk_request(), encryption_on(), att(write(configuration(enc_n), <<1, 0>>)), {kept, {ok, ?KEPT_ID}}]
             ++ [{notify, I, notify, {svc, enc_n}, <<"n">>} || I <- lists:seq(1, ?SHARE + ?QUEUE + 1)],
    {Actions, Core} = run(Inputs, bonded(unauthenticated)),
    Replies = [Reply || {reply, _, Reply} <- Actions],
    ?assertEqual(lists:duplicate(?SHARE - 1 + ?QUEUE, ok) ++ [{error, busy}, {error, busy}], Replies),
    ?assertMatch(#{queued := ?QUEUE, outstanding := ?SHARE}, facts(Core)),
    {More, _} = core_step({completed, ?SHARE}, 0, Core),
    ?assertEqual(?SHARE, length([A || {acl, _, _} = A <- More])).

%% An indication is answered at the phone's confirmation; unconfirmed in 30 s, the
%% caller hears `timeout` and the link ends (Part F, 3.3.3).
indication_test() ->
    Subscribe = att(write(configuration(ind), <<2, 0>>)),
    Indicate = {notify, caller, indicate, {svc, ind}, <<"i">>},
    {Confirmed, _} = run([Subscribe, Indicate, att(confirm())]),
    ?assertEqual([{reply, caller, ok}], [A || {reply, _, _} = A <- Confirmed]),
    {Timed, _} = run([Subscribe, Indicate, {at, 30000, expired}]),
    ?assertEqual([{reply, caller, {error, timeout}}], [A || {reply, _, _} = A <- Timed]),
    ?assertEqual([att_timeout], closed(Timed)).

%% ---- the one key and encryption ----

%% A reconnection: the bond's key answers the request and the level is the bond's.
reconnection_reaches_bond_level_test() ->
    {Actions, Core} = run([ltk_request(), encryption_on()], bonded(authenticated)),
    ?assertEqual([{ltk_reply, ?BOND_LTK}], [A || {ltk_reply, _} = A <- Actions]),
    ?assertEqual([{security, #{level => authenticated, bond => ?BOND_ID}}], registry(Actions)),
    ?assertMatch(#{encrypted := true, key := authenticated}, facts(Core)).

%% A bonded link tells the registry its bond's id and no address: two connections of one
%% bond, each from its own resolvable private address, carry the same id. (A link not yet
%% bonded tells `none`: first_pairing_reaches_level_before_store_test; a resolved link
%% tells nothing before its encryption: resolved_bond_is_taken_on_at_encryption_test.)
bonded_link_reports_the_bonds_id_test() ->
    Reported = [registry(element(1, run([ltk_request(), encryption_on()],
                                        core(#{addresses => #{central => Rpa, peripheral => ?PERIPHERAL},
                                               bond => resolved(authenticated, #{})}))))
                || Rpa <- [?RPA1, ?RPA2]],
    ?assertEqual(lists:duplicate(2, [{security, #{level => authenticated, bond => ?BOND_ID}}]),
                 Reported).

%% Secure Connections' request carries zero Rand and EDIV; any other, and every request on
%% a link with no key, is answered Negative Reply.
negative_reply_test() ->
    {Other, _} = run([{le_long_term_key_request, 1, <<1:64>>, 7}], bonded(authenticated)),
    ?assertEqual([{ltk_reply, none}], Other),
    {NoKey, _} = run([ltk_request()]),
    ?assertEqual([{ltk_reply, none}], NoKey).

%% A Reply the controller answered with a failure counts as no Reply: the next report
%% about encryption ends the link; one answered `ok` encrypts.
failed_reply_counts_as_none_test() ->
    {Failed, Core} = run([ltk_request(), {ltk_reply_complete, {failed, 16#0C}}, encryption_on()],
                         bonded(authenticated)),
    ?assertEqual([{encryption, encryption_change}], closed(Failed)),
    ?assertMatch(#{encrypted := false}, facts(Core)),
    {_, Ok} = run([ltk_request(), {ltk_reply_complete, ok}, encryption_on()], bonded(authenticated)),
    ?assertMatch(#{encrypted := true}, facts(Ok)).

%% A report after a Negative Reply, without a request, with an error or turning
%% encryption off ends the link and encrypts nothing.
negative_reply_then_change_ends_link_test() ->
    Bonded = bonded(authenticated),
    [begin
         {Actions, Core} = run(Inputs, Bonded),
         ?assertMatch([{encryption, _}], closed(Actions)),
         ?assertMatch(#{encrypted := false}, facts(Core))
     end || Inputs <- [[{le_long_term_key_request, 1, <<1:64>>, 7}, encryption_on()],
                       [encryption_on()],
                       [{encryption_key_refresh_complete, 0, 1}],
                       [ltk_request(), {encryption_change, 16#06, 1, 1}],
                       [ltk_request(), {encryption_change, 0, 1, 0}]]].

%% Key Refresh after a Reply encrypts too (7.7.39).
key_refresh_encrypts_test() ->
    {_, Core} = run([ltk_request(), {encryption_key_refresh_complete, 0, 1}], bonded(unauthenticated)),
    ?assertMatch(#{encrypted := true}, facts(Core)).

%% A link with a bond's key never pairs: the window's `open` verdict reaches the Security
%% Manager as `bonded`, which fails the request, Unspecified Reason, and keeps the key.
bonded_link_never_pairs_test() ->
    Core = bonded(unauthenticated),
    {Actions, After} = run([smp(pairing_request()), {admission, 1, {open, nodisplay, fresh()}},
                            ltk_request()], Core),
    ?assertEqual([{admit, 1, ?CENTRAL}, {outcome, 1, {failed, already_bonded}}], window(Actions)),
    ?assertEqual([pairing_failed(16#08)], on(6, Actions)),
    ?assertEqual([{ltk_reply, ?BOND_LTK}], [A || {ltk_reply, _} = A <- Actions]),
    ?assertMatch(#{key := unauthenticated}, facts(After)).

%% Nothing the link shows holds a secret.
facts_hold_no_secret_test() ->
    {_, Core} = run([ltk_request(), encryption_on()], bonded(authenticated)),
    ?assertEqual(nomatch, binary:match(term_to_binary(facts(Core)), ?BOND_LTK)).

%% ---- a pairing through the link ----

key(Seed) ->
    {<<4, X:32/binary, Y:32/binary>>, Private} = crypto:generate_key(ecdh, secp256r1, crypto:hash(sha256, <<Seed>>)),
    {Private, {X, Y}}.

nonces(Seed) -> [crypto:hash(md5, <<Seed, I>>) || I <- lists:seq(1, 20)].

fresh() ->
    {Private, Public} = key(1),
    #{private => Private, public => Public, nonces => nonces(1), passkey => 123456}.

%% The honest phone's Just Works pairing as SMP PDUs (Part H, 2.3.5.6.2 and 2.3.5.6.5,
%% 3.5 and 3.6), computed independently with erx_smp_crypto, and the LTK it agrees.
just_works() ->
    {PhonePrivate, {X, Y} = PhonePublic} = key(2),
    {_, Own} = key(1),
    [Na | _] = nonces(2),
    [Nb | _] = nonces(1),
    {MacKey, Ltk} = erx_smp_crypto:f5(erx_smp_crypto:dhkey(PhonePrivate, Own), Na, Nb, ?CENTRAL, ?PERIPHERAL),
    Ea = erx_smp_crypto:f6(MacKey, Na, Nb, <<0:128>>, <<16#2D, 0, 16#03>>, ?CENTRAL, ?PERIPHERAL),
    _ = PhonePublic,
    {[<<16#0C, (rev(X))/binary, (rev(Y))/binary>>, <<16#04, (rev(Na))/binary>>, <<16#0D, (rev(Ea))/binary>>], Ltk}.

rev(Bytes) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).

%% A first pairing reaches its level at the controller's encryption, before the store
%% answers. The step that ends its third phase is its one ordering point: it sends `keep`
%% to the store and `keeping` to the window together, and a withdrawal after it changes
%% nothing. The outcome is then the store's to tell the window: the store's `ok` makes the
%% key a kept bond's, and its error ends the link.
first_pairing_reaches_level_before_store_test() ->
    {[PublicKey, Random, Check], Ltk} = just_works(),
    {Paired, Encrypted} = run([smp(pairing_request()), {admission, 1, {open, nodisplay, fresh()}}, smp(PublicKey),
                               smp(Random), smp(Check), ltk_request(), encryption_on(), smp(<<16#08, 7:128>>)],
                              core(#{share => 16})),
    ?assertEqual([], [Code || <<16#05, Code>> <- on(6, Paired)]),
    ?assertEqual([{ltk_reply, Ltk}], [A || {ltk_reply, _} = A <- Paired]),
    ?assertEqual([{security, #{level => encrypted, bond => none}}], registry(Paired)),
    ?assertEqual([], [A || {store, _} = A <- Paired]),
    {Ended, Core} = core_step(smp(<<16#09, 1, 16#C6, 16#C5, 16#C4, 16#C3, 16#C2, 16#C1>>), 0, Encrypted),
    ?assertMatch([{store, {keep, 1, #{ltk := Ltk, level := unauthenticated}, #{}}}, {window, {keeping, 1}}],
                 [A || {Role, _} = A <- Ended, Role =:= store orelse Role =:= window]),
    ?assertMatch({[], _}, core_step({withdraw, 1}, 0, Core)),
    {Kept, _} = core_step({kept, {ok, ?KEPT_ID}}, 0, Core),
    ?assertEqual([{registry, {security, #{level => encrypted, bond => ?KEPT_ID}}}], Kept),
    {Failed, _} = core_step({kept, {error, unavailable}}, 0, Core),
    ?assertEqual([{close, {store, unavailable}}], Failed).

%% The honest phone's Passkey Entry pairing (Part H, 2.3.5.6.3 and 2.3.5.6.5, 3.5 and 3.6):
%% a keyboard phone and the fresh passkey erXos displays, one commit and one nonce a round
%% for twenty rounds, round i's bit being bit i of the passkey, least significant first
%% (as erx_bt_smp_tests takes it), and the DHKey check over the passkey. Returns its PDUs
%% in order and the LTK it agrees.
passkey_pairing() ->
    {PhonePrivate, {X, Y} = PhonePublic} = key(2),
    {_, {OwnX, _} = Own} = key(1),
    Passkey = maps:get(passkey, fresh()),
    Na = nonces(2),
    Rounds = [[<<16#03, (rev(erx_smp_crypto:f4(element(1, PhonePublic), OwnX, Nonce, 16#80 bor ((Passkey bsr Round) band 1))))/binary>>,
               <<16#04, (rev(Nonce))/binary>>]
              || {Round, Nonce} <- lists:zip(lists:seq(0, 19), Na)],
    {MacKey, Ltk} = erx_smp_crypto:f5(erx_smp_crypto:dhkey(PhonePrivate, Own), lists:last(Na), lists:last(nonces(1)),
                                      ?CENTRAL, ?PERIPHERAL),
    Ea = erx_smp_crypto:f6(MacKey, lists:last(Na), lists:last(nonces(1)), <<Passkey:128>>, <<16#2D, 0, 16#04>>,
                           ?CENTRAL, ?PERIPHERAL),
    {[<<16#0C, (rev(X))/binary, (rev(Y))/binary>> | lists:append(Rounds)] ++ [<<16#0D, (rev(Ea))/binary>>], Ltk}.

%% A write to a `bonded` characteristic on a pairing link whose key is authenticated, by a
%% Passkey Entry pairing, but not yet a kept bond's, is Insufficient Authentication and
%% reaches no handler; once the store has kept the bond, the same write is handed out.
bonded_write_waits_for_the_kept_bond_test() ->
    {Pdus, Ltk} = passkey_pairing(),
    Write = att(write(handle(bond_w), <<"b">>)),
    {Paired, Ended} = run([smp(<<16#01, 16#04, 0, 16#2D, 16, 16#0B, 16#0B>>), {admission, 1, {open, display, fresh()}}]
                          ++ [smp(Pdu) || Pdu <- Pdus]
                          ++ [ltk_request(), encryption_on(), smp(<<16#08, 7:128>>),
                              smp(<<16#09, 1, 16#C6, 16#C5, 16#C4, 16#C3, 16#C2, 16#C1>>)],
                          core(#{share => 64})),
    ?assertEqual([], [Code || <<16#05, Code>> <- on(6, Paired)]),
    ?assertEqual([{ltk_reply, Ltk}], [A || {ltk_reply, _} = A <- Paired]),
    ?assertMatch([{store, {keep, 1, #{level := authenticated}, #{}}}], [A || {store, _} = A <- Paired]),
    {Pairing, _} = core_step(Write, 0, Ended),
    ?assertEqual([error_rsp(16#12, handle(bond_w), 16#05)], on(4, Pairing)),
    ?assertEqual([], registry(Pairing)),
    {_, Kept} = core_step({kept, {ok, ?KEPT_ID}}, 0, Ended),
    {Handed, _} = core_step(Write, 0, Kept),
    ?assertEqual([{write, 1, {svc, bond_w}, <<"b">>}], registry(Handed)).

%% Every message is keyed by its role: a controller message's step answers `taken` first,
%% packets and the Long Term Key answer go to the controller as `hci`, the store's
%% `forgotten` ends the link, and an input without its role, or under another's, raises.
roles_test() ->
    {Reply, _} = erx_bt_link_core:step({hci, ltk_request()}, 0, bonded(authenticated)),
    ?assertEqual([{hci, taken}, {hci, {ltk_reply, ?BOND_LTK}}], Reply),
    {Rejected, _} = erx_bt_link_core:step({hci, acl(5, <<16#12, 7, 8:16/little, 0:64>>)}, 0, core()),
    ?assertMatch([{hci, taken}, {hci, {send, 0, _}}], Rejected),
    ?assertMatch({[], _}, erx_bt_link_core:step({registry, {set, {svc, open_w}, <<"v">>}}, 0, core())),
    ?assertMatch({[{close, forgotten}], _}, erx_bt_link_core:step({store, forgotten}, 0, bonded(authenticated))),
    ?assertError(function_clause, erx_bt_link_core:step(ltk_request(), 0, core())),
    ?assertError(function_clause, erx_bt_link_core:step({window, {set, {svc, open_w}, <<"v">>}}, 0, core())),
    ?assertError(function_clause, erx_bt_link_core:step({store, {kept, {ok, ?KEPT_ID}}}, 0, core())).

%% A resolved bond is a candidate until the link is encrypted with its key: before that the
%% link has the default configuration and answers a configuration write Insufficient
%% Encryption (0x0F); at encryption it takes on the bond's subscriptions the table still
%% declares, which the registry hears, and a notification goes out.
resolved_bond_is_taken_on_at_encryption_test() ->
    Core = core(#{bond => resolved(unauthenticated, #{{svc, enc_n} => notify, {svc, gone} => notify})}),
    Config = configuration(enc_n),
    Notify = {notify, caller, notify, {svc, enc_n}, <<"n">>},
    {Before, _} = run([att(read(Config)), att(write(Config, <<1, 0>>))], Core),
    ?assertEqual([<<16#0B, 0, 0>>, error_rsp(16#12, Config, 16#0F)], on(4, Before)),
    ?assertEqual([], registry(Before)),
    {At, _} = run([ltk_request(), encryption_on(), att(read(Config)), Notify], Core),
    ?assertEqual([{security, #{level => encrypted, bond => ?BOND_ID}},
                  {subscribed, {svc, enc_n}, notify}],
                 registry(At)),
    ?assertEqual([{reply, caller, ok}], [A || {reply, _, _} = A <- At]),
    ?assertMatch([<<16#0B, 1, 0>>, <<16#1B, _:16, "n">>], on(4, At)).

%% Before its encryption a resolved link refuses a configuration write Insufficient
%% Encryption even for `ind`, open to every link: the configuration is the bond's to take
%% on at its encryption, so the phone neither hears it accepted nor reaches the registry
%% or the store with it.
resolved_link_refuses_an_open_configuration_before_encryption_test() ->
    {Actions, _} = run([att(write(configuration(ind), <<2, 0>>))], bonded(unauthenticated)),
    ?assertEqual([error_rsp(16#12, configuration(ind), 16#0F)], on(4, Actions)),
    ?assertEqual([], registry(Actions) ++ [A || {store, _} = A <- Actions]).

%% A failure that ends a keyed link sends its Pairing Failed before the close: a pairing
%% withdrawn after its second phase gave the link its key (docs/design-bluetooth.md, "The
%% pairing window").
withdrawn_after_key_sends_failure_before_close_test() ->
    {[PublicKey, Random, Check], _Ltk} = just_works(),
    {_, Keyed} = run([smp(pairing_request()), {admission, 1, {open, nodisplay, fresh()}}, smp(PublicKey),
                      smp(Random), smp(Check)], core(#{share => 16})),
    {Actions, _} = core_step({withdraw, 1}, 0, Keyed),
    ?assertEqual([pairing_failed(16#08)], on(6, Actions)),
    ?assertEqual([{withdrawn, 1}], window(Actions)),
    ?assertEqual({close, pairing}, lists:last(Actions)).

%% A Pairing Request after the bond is refused, but that is no outcome for the window,
%% which heard the pairing's own already.
done_refusal_not_an_outcome_test() ->
    {[PublicKey, Random, Check], _Ltk} = just_works(),
    Identity = [smp(<<16#08, 7:128>>), smp(<<16#09, 1, 16#C6, 16#C5, 16#C4, 16#C3, 16#C2, 16#C1>>)],
    {_, Bonded} = run([smp(pairing_request()), {admission, 1, {open, nodisplay, fresh()}}, smp(PublicKey),
                       smp(Random), smp(Check), ltk_request(), encryption_on()] ++ Identity ++ [{kept, {ok, ?KEPT_ID}}],
                      core(#{share => 16})),
    {Actions, _} = run([smp(pairing_request())], Bonded),
    ?assertEqual([pairing_failed(16#08)], on(6, Actions)),
    ?assertEqual([], window(Actions)).

%% A failure of the pairing the link sent to admit reaches the window while the verdict is
%% still on its way, since the link cannot know it; the window takes a failure only of a
%% pairing it opened, so one it refused changes nothing there (docs/design-bluetooth.md,
%% "The pairing window"). The verdict that comes after changes nothing at the link.
failure_before_the_verdict_reaches_the_window_test() ->
    {_, Admitting} = run([smp(pairing_request())]),
    {Failed, Idle} = run([smp(pairing_failed(16#08))], Admitting),
    ?assertMatch([{outcome, 1, {failed, _}}], window(Failed)),
    [?assertEqual({[], Idle}, core_step({admission, 1, Verdict}, 0, Idle))
     || Verdict <- [closed, waiting, {open, nodisplay, fresh()}]].

%% The Security Manager Timer is a deadline: 30 s without a step fails the pairing and
%% ends the link (Part H, 3.4).
pairing_deadline_test() ->
    {_, Core} = run([smp(pairing_request())], core()),
    ?assertEqual(30000, erx_bt_link_core:next_deadline(Core)),
    {Actions, _} = core_step(expired, 30000, Core),
    ?assertEqual([{outcome, 1, {failed, timeout}}], window(Actions)),
    ?assertEqual([pairing], closed(Actions)).

%% ---- reconnection ----

%% A resolved link asks the window for the pairing wait at its start, at `now`, and each
%% `Ms` the window answers after; at `0` it sends one Security Request with the bond's
%% AuthReq, bonding, SC and, for an authenticated bond, MITM (Part H, 3.5.1, 3.6.7), and
%% asks nothing more. A phone that has begun pairing or encryption gets none (2.4.6), an answer that
%% comes after the encryption changes nothing, and a link with no bond never asks.
security_request_once_never_during_encryption_test() ->
    Core = bonded(authenticated),
    ?assertEqual(0, erx_bt_link_core:next_deadline(Core)),
    {Asked, Asking} = core_step(expired, 0, Core),
    ?assertEqual([{window, wait}], Asked),
    ?assertEqual(infinity, erx_bt_link_core:next_deadline(Asking)),
    {Later, Waiting} = core_step({wait, 5000}, 0, Asking),
    ?assertEqual([], Later),
    ?assertEqual(5000, erx_bt_link_core:next_deadline(Waiting)),
    {Again, Asking2} = core_step(expired, 5000, Waiting),
    ?assertEqual([{window, wait}], Again),
    {Request, Done} = core_step({wait, 0}, 5000, Asking2),
    ?assertEqual([<<16#0B, 16#0D>>], on(6, Request)),
    ?assertEqual(infinity, erx_bt_link_core:next_deadline(Done)),
    {Unauthenticated, _} = run([expired, {wait, 0}], bonded(unauthenticated)),
    ?assertEqual([<<16#0B, 16#09>>], on(6, Unauthenticated)),
    {DuringEncryption, Begun} = run([expired, ltk_request(), {wait, 0}], Core),
    ?assertEqual([], on(6, DuringEncryption)),
    ?assertEqual(infinity, erx_bt_link_core:next_deadline(Begun)),
    {DuringPairing, _} = run([expired, smp(pairing_request()), {wait, 0}], Core),
    ?assertEqual([], [R || <<16#0B, _>> = R <- on(6, DuringPairing)]),
    {AfterEncryption, _} = run([expired, ltk_request(), encryption_on(), {wait, 0}], Core),
    ?assertEqual([], on(6, AfterEncryption)),
    ?assertEqual(infinity, erx_bt_link_core:next_deadline(core())),
    ?assertError(function_clause, core_step({wait, 0}, 0, core())).

%% A configuration write on a link encrypted with a kept bond's key is answered only once
%% the store has kept the new configuration (docs/design-bluetooth.md, "Bonds and the
%% store"): the store is sent the link's whole configuration with the change, and the Write
%% Response and `subscribed` follow its `ok`; its error is Unlikely Error (0x0E) and leaves
%% the configuration as it was. A write that changes nothing is answered at once.
bonded_configuration_write_waits_for_the_store_test() ->
    Config = configuration(enc_n),
    Bonded = core(#{bond => resolved(unauthenticated, #{}), share => 16}),
    {_, Encrypted} = run([ltk_request(), encryption_on()], Bonded),
    {Asked, Writing} = run([att(write(Config, <<1, 0>>))], Encrypted),
    ?assertEqual([{store, {subscriptions, #{{svc, enc_n} => notify}}}], [A || {store, _} = A <- Asked]),
    ?assertEqual([], on(4, Asked)),
    ?assertEqual([], registry(Asked)),
    {Kept, _} = run([{kept, {ok, ?KEPT_ID}}], Writing),
    ?assertEqual([write_rsp()], on(4, Kept)),
    ?assertEqual([{subscribed, {svc, enc_n}, notify}], registry(Kept)),
    {Failed, Unchanged} = run([{kept, {error, unavailable}}, att(read(Config))], Writing),
    ?assertEqual([error_rsp(16#12, Config, 16#0E), <<16#0B, 0, 0>>], on(4, Failed)),
    ?assertEqual([], registry(Failed)),
    ?assertEqual([], closed(Failed)),
    {Same, _} = run([att(write(Config, <<0, 0>>))], Unchanged),
    ?assertEqual([write_rsp()], on(4, Same)),
    ?assertEqual([], [A || {store, _} = A <- Same]).

%% A configuration write while the store keeps the pairing's bond waits for its answer to
%% `keep`, and is then kept as a bonded link's, so `keep` never leaves out a subscription the
%% phone saw answered.
configuration_write_while_keeping_waits_for_the_keep_test() ->
    {[PublicKey, Random, Check], _Ltk} = just_works(),
    Identity = [smp(<<16#08, 7:128>>), smp(<<16#09, 1, 16#C6, 16#C5, 16#C4, 16#C3, 16#C2, 16#C1>>)],
    {_, Keeping} = run([smp(pairing_request()), {admission, 1, {open, nodisplay, fresh()}}, smp(PublicKey),
                        smp(Random), smp(Check), ltk_request(), encryption_on()] ++ Identity,
                       core(#{share => 16})),
    {Held, Holding} = run([att(write(configuration(ind), <<2, 0>>))], Keeping),
    ?assertEqual([], on(4, Held) ++ [A || {store, _} = A <- Held]),
    {Bonded, Writing} = run([{kept, {ok, ?KEPT_ID}}], Holding),
    ?assertEqual([{registry, {security, #{level => encrypted, bond => ?KEPT_ID}}},
                  {store, {subscriptions, #{{svc, ind} => indicate}}}], Bonded),
    {Kept, _} = run([{kept, {ok, ?KEPT_ID}}], Writing),
    ?assertEqual([write_rsp()], on(4, Kept)),
    ?assertEqual([{subscribed, {svc, ind}, indicate}], registry(Kept)).

%% At the encryption with a resolved bond's key, a table whose hash is not the bond's is
%% indicated as Service Changed for every handle (Part G, 2.5.2, 7.1) when the bond kept a
%% subscription to it, and the confirmation sends the store the table's hash; a bond served
%% this table, or not subscribed, gets none. Unconfirmed in 30 s, it ends the link.
service_changed_at_reconnection_test() ->
    {ok, #{value := Handle}} = erx_gatt_db:characteristic(erx_gatt_db:service_changed(), table()),
    Subscribed = #{erx_gatt_db:service_changed() => indicate},
    Encrypt = [ltk_request(), encryption_on()],
    {Indicated, Waiting} = run(Encrypt, core(#{bond => resolved(unauthenticated, Subscribed)})),
    ?assertEqual([<<16#1D, Handle:16/little, 16#01, 16#00, 16#FF, 16#FF>>], on(4, Indicated)),
    ?assertEqual([], [A || {store, _} = A <- Indicated]),
    {Confirmed, _} = run([att(confirm())], Waiting),
    ?assertEqual([{store, {served, erx_gatt_db:hash(table())}}], Confirmed),
    ?assertEqual(30000, erx_bt_link_core:next_deadline(Waiting)),
    {Unconfirmed, _} = core_step(expired, 30000, Waiting),
    ?assertEqual([att_timeout], closed(Unconfirmed)),
    Served = (resolved(unauthenticated, Subscribed))#{hash := erx_gatt_db:hash(table())},
    {Same, _} = run(Encrypt, core(#{bond => Served})),
    ?assertEqual([], on(4, Same)),
    {Unsubscribed, _} = run(Encrypt, bonded(unauthenticated)),
    ?assertEqual([], on(4, Unsubscribed)).

%% ---- the core, explored ----

%% Every state a small alphabet reaches within ?DEPTH steps, from a link with no key and
%% from a resolved one subscribed to enc_n. Each step keeps the invariants:
%% the queue and the outstanding packets within their bounds, no packet past the
%% controller's length, a key never changing once set, `encrypted` set only by a success
%% report after a Reply and only on a link with a key, no write to an `encrypted`
%% characteristic reaching the registry on a link not encrypted, a Reply only with a key,
%% every whole frame on an unknown channel counted, no subscription to enc_n heard before
%% the link is encrypted, and every controller message's step answering `taken` first
%% (core_step/3); at most one `wait` unanswered and one Security Request on a path, never
%% once the phone has begun encryption; no `subscriptions` or `served` sent and no Service
%% Changed indicated on a link that is not its bond's; on a bonded link the configuration
%% changed only at the store's `ok`; and the registry told a bond's id exactly where the
%% link is bonded, and only the resolved bond's.
%% The window's and the store's answers are offered only when asked for. A step that ends
%% the link ends its path.
explored_core_keeps_its_invariants_test_() ->
    {timeout, 300, fun explore/0}.

explore() ->
    Kept = #{{svc, enc_n} => notify, erx_gatt_db:service_changed() => indicate},
    Starts = [{C, 0, 0, #{}} || Bond <- [none, resolved(unauthenticated, Kept)], C <- [core(#{bond => Bond})]],
    Visited = explore(Starts, maps:from_keys(Starts, true), ?DEPTH),
    io:format("~b states~n", [map_size(Visited)]),
    ?assert(map_size(Visited) > 1000).

explore(_Frontier, Visited, 0) ->
    Visited;
explore(Frontier, Visited, Depth) ->
    Next = lists:usort([N || State <- Frontier, Input <- alphabet(State), N <- [explore_step(Input, State)],
                             N =/= closed, not maps:is_key(N, Visited)]),
    explore(Next, lists:foldl(fun(N, V) -> V#{N => true} end, Visited, Next), Depth - 1).

alphabet({Core, Now, Ref, Asked}) ->
    [att(write(handle(open_w), <<"w">>)), att(write(handle(enc_w), <<"e">>)), att(write_cmd(handle(open_w), <<"c">>)),
     att(write(configuration(enc_n), <<1, 0>>)), att(write(configuration(enc_n), <<0, 0>>)),
     att(write_cmd(configuration(enc_n), <<0, 0>>)), att(confirm()), acl(16#0040, <<1>>), acl(5, <<16#12, 1, 0:16>>),
     smp(pairing_request()), {admission, 1, closed}, {acl, 2, <<3:16/little>>}, {acl, 1, <<4, 0, 16#0A, 3, 0>>},
     ltk_request(), {le_long_term_key_request, 1, <<1:64>>, 1}, encryption_on(), {encryption_change, 5, 1, 1},
     {encryption_key_refresh_complete, 0, 1}, {answer, Ref, ok},
     {ltk_reply_complete, ok}, {ltk_reply_complete, {failed, 16#0C}}, {notify, n, notify, {svc, enc_n}, <<"n">>}]
    ++ [{completed, 1} || maps:get(outstanding, facts(Core)) > 0]
    ++ [Wait || is_map_key(wait, Asked), Wait <- [{wait, 0}, {wait, 1000}]]
    ++ [Kept || is_map_key(store, Asked), Kept <- [{kept, {ok, ?KEPT_ID}}, {kept, {error, unavailable}}]]
    ++ [{at, D, expired} || D <- [erx_bt_link_core:next_deadline(Core)], D =/= infinity, D >= Now].

explore_step({at, Now, Input}, {Core, _, Ref, Asked}) -> explore_step(Input, {Core, Now, Ref, Asked});
explore_step(Input, {Core, Now, Ref, Asked}) ->
    Before = facts(Core),
    {Actions, Next} = core_step(Input, Now, Core),
    After = facts(Next),
    #{outstanding := Outstanding, queued := Queued} = After,
    ?assert(Outstanding =< ?SHARE),
    ?assert(Queued =< ?QUEUE + 2),
    [?assert(byte_size(Data) =< ?ACL_TX_MAX) || {acl, _, Data} <- Actions],
    [?assertEqual(maps:get(key, Before), maps:get(key, After)) || maps:get(key, Before) =/= none],
    case {maps:get(encrypted, Before), maps:get(encrypted, After)} of
        {false, true} -> ?assert(success_report(Input) andalso maps:get(ltk_answer, Before) =:= replied);
        _ -> ok
    end,
    [?assertNotEqual(none, maps:get(key, After)) || maps:get(encrypted, After)],
    [?assert(maps:get(encrypted, After)) || {registry, {write, _, {svc, enc_w}, _}} <- Actions],
    [?assert(maps:get(encrypted, After)) || {registry, {subscribed, {svc, enc_n}, notify}} <- Actions],
    [?assertNotEqual(none, maps:get(key, Before)) || {ltk_reply, Ltk} <- Actions, Ltk =/= none],
    Waits = [wait || {window, wait} <- Actions],
    Requests = [R || <<16#0B, _>> = R <- on(6, Actions)],
    [?assertNot(is_map_key(wait, Asked)) || Waits =/= []],
    [?assertNot(is_map_key(requested, Asked)) || Requests =/= []],
    %% A Security Request is decided only at `{wait, 0}`, which queues nothing else; once
    %% pairing or encryption has begun that step neither sends nor queues nor refuses a frame.
    case Input of
        {wait, 0} when map_get(ltk_answer, Before) =/= none; map_get(encrypted, Before); map_get(pairing, Before) ->
            ?assertEqual([], Requests),
            ?assert(maps:get(queued, After) =< maps:get(queued, Before)),
            ?assertEqual(maps:get(refused, Before), maps:get(refused, After));
        _ -> ok
    end,
    %% The registry hears a bond's id exactly where the gate's `bonded` holds, and the id
    %% is the resolved bond's: the alphabet admits no pairing, so a link is bonded only by
    %% the resolved bond's key.
    [?assertEqual(maps:get(bonded, After), Bond =/= none) || {registry, {security, #{bond := Bond}}} <- Actions],
    [?assert(Bond =:= none orelse Bond =:= ?BOND_ID) || {registry, {security, #{bond := Bond}}} <- Actions],
    ToStore = [Message || {store, Message} <- Actions, element(1, Message) =/= keep],
    [?assert(maps:get(bonded, After) andalso maps:get(encrypted, After) andalso maps:get(key, After) =/= none)
     || _ <- ToStore],
    [?assert(maps:get(encrypted, After))
     || <<16#1D, H:16/little, _/binary>> <- on(4, Actions), H =:= service_changed()],
    case maps:get(bonded, Before) andalso Input =/= {kept, {ok, ?KEPT_ID}} of
        true -> ?assertEqual([], [S || {registry, {subscribed, _, _}} = S <- Actions]);
        false -> ok
    end,

    case closed(Actions) of
        [] ->
            [?assertEqual(maps:get(dropped, Before) + 1, maps:get(dropped, After)) || Input =:= acl(16#0040, <<1>>)],
            Answered = case Input of
                           {wait, _} -> maps:remove(wait, Asked);
                           {kept, _} -> maps:remove(store, Asked);
                           _ -> Asked
                       end,
            %% The answers now owed, and whether this path has sent its Security Request.
            Pending = [store || {store, M} <- Actions, element(1, M) =/= served]
                      ++ [wait || _ <- Waits] ++ [requested || _ <- Requests],
            {Next, Now, lists:max([Ref | [R || {registry, {write, R, _, _}} <- Actions]]),
             maps:merge(Answered, maps:from_keys(Pending, true))};
        _ -> closed
    end.

service_changed() ->
    {ok, #{value := Handle}} = erx_gatt_db:characteristic(erx_gatt_db:service_changed(), table()),
    Handle.

success_report({encryption_change, 0, _, 1}) -> true;
success_report({encryption_key_refresh_complete, 0, _}) -> true;
success_report(_) -> false.
