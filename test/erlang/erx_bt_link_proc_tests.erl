%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the link process, erx_bt_link (docs/design-bluetooth.md, "The link's
%% messages"), over stand-ins: the case's own process is the controller process, and three
%% processes registered as the window (erx_bt_fs), the registry (erx_gatt_srv) and the
%% store (erx_bt_store) pass on what the link sends them; the store's answers `resolve`
%% with the case's bond and the registry's `join` with the table, at once or when the case
%% releases them. The start, which waits for neither call; a call that fails ending the
%% link; a Just Works pairing whose one ordering point sends `keep` and `keeping`; a
%% withdrawal before it failing the pairing and after it changing nothing; a killed link
%% seen by its owners through 'DOWN'; a reconnection that takes on the bond at encryption;
%% notifications as requests; a crash mid-pairing that shows no secret; the handler's
%% deadline on the wake-up timer; and format_status/1 hiding the window's fresh values in a
%% message and the sys log. PDUs are written from the Core Specification 6.3's numbers
%% (Vol 3 Parts A, F and H; Vol 4 Part E, 7.7.8 and 7.7.65.5).

-module(erx_bt_link_proc_tests).

-include_lib("eunit/include/eunit.hrl").
-define(GAP, #{name => <<"erxos">>, appearance => 0}).

-export([log/2]).

-define(CENTRAL_ADDRESS, <<16#C0, 16#FF, 16#EE, 16#12, 16#34, 16#56>>).
-define(OWN_ADDRESS, <<16#D1, 16#E2, 16#F3, 16#A4, 16#B5, 16#C6>>).
-define(CENTRAL, {random, ?CENTRAL_ADDRESS}).
-define(PERIPHERAL, {random, ?OWN_ADDRESS}).
-define(BOND_LTK, <<16#B0:128>>).
%% The identity address identity() distributes (type 1, random), decoded: most significant
%% octet first, where the PDU sends it least significant octet first.
-define(DISTRIBUTED, {random, <<16#C1, 16#C2, 16#C3, 16#C4, 16#C5, 16#C6>>}).
-define(BOND, #{id => <<"00000000000000000000000000000001">>, ltk => ?BOND_LTK, level => authenticated, identity => ?CENTRAL, hash => <<0:256>>,
                subscriptions => #{{svc, n} => notify}}).
-define(NAME, {16#40, 1}).
-define(PASSKEY, 123456).
-define(WAIT_MS, 2000).

%% ---- the cases ----

%% start_link/1 returns while the store and the registry hold the link's calls; what the
%% controller process sends meanwhile is stepped in order once they answer, and the phone's
%% address resolved to a bond gets its key.
start_waits_for_neither_call_test() ->
    with_owners(#{bond => ?BOND, hold => true}, fun() ->
        Test = self(),
        spawn_link(fun() -> Test ! {started, start(Test)} end),
        Link = receive {started, L} -> L after 1000 -> error(start_waited) end,
        hci(Link, {le_long_term_key_request, 16#40, <<0:64>>, 0}),
        phone_att(Link, <<16#12, (handle(open_w)):16/little, "hi">>),
        [gen_server:reply(From, Answer) || Owner <- [erx_bt_store, erx_gatt_srv],
                                           {held, _, From, Answer} <- [held(Owner)]],
        ?assertEqual({ltk_reply, ?BOND_LTK}, from_link()),
        ?assertMatch({write, _Ref, {svc, open_w}, <<"hi">>}, told(erx_gatt_srv)),
        exit(Link, kill)
    end).

%% A link whose registry is not running ends at its start, before any step.
failed_join_ends_the_link_test() ->
    with_owners(#{absent => [erx_gatt_srv]}, fun() ->
        Link = start(self()),
        ?assertEqual({shutdown, {start, registry}},
                     receive {'EXIT', Link, R} -> R after 7000 -> error(link_not_ended) end)
    end).

%% A Just Works pairing through the link process: the window admits it, the controller is
%% answered with the pairing's LTK and the registry hears the link encrypted. The step that
%% ends the third phase sends `keep`, with the pairing's tag, to the store and `keeping` to
%% the window; a withdrawal after it changes nothing. The store's ok makes the key a kept
%% bond's, which the registry hears as `bonded`; the outcome is the store's to tell the
%% window, so the link tells the window nothing more.
just_works_pairing_to_the_store_test() ->
    with_owners(#{}, fun() ->
        Link = start(self()),
        {PhonePdus, Ltk} = just_works(),
        Tag = admitted(Link),
        [phone(Link, Pdu) || Pdu <- PhonePdus],
        hci(Link, {le_long_term_key_request, 16#40, <<0:64>>, 0}),
        ?assertEqual({ltk_reply, Ltk}, from_link()),
        hci(Link, {ltk_reply_complete, ok}),
        hci(Link, {encryption_change, 0, 16#40, 1}),
        ?assertEqual({security, #{level => encrypted, bonded => false}}, told(erx_gatt_srv)),
        [phone(Link, Pdu) || Pdu <- identity()],
        ?assertMatch({Link, {keep, Tag, #{ltk := Ltk, level := unauthenticated}, #{}}}, addressed(erx_bt_store)),
        ?assertEqual({Link, {keeping, Tag}}, addressed(erx_bt_fs)),
        Link ! {window, {withdraw, Tag}},
        Link ! {store, {kept, {ok, <<"00000000000000000000000000000001">>}}},
        ?assertEqual({security, #{level => encrypted, bonded => true, identity => ?DISTRIBUTED}}, told(erx_gatt_srv)),
        ?assertEqual([], [Code || <<_:16, 6:16/little, 16#05, Code>> <- sent()]),
        ?assertEqual(nothing, next(erx_bt_fs))
    end).

%% A window that closes before the link's `keeping` fails the pairing `withdrawn`: the
%% phone hears Pairing Failed, Unspecified Reason, and the store is asked nothing.
withdrawn_before_keeping_test() ->
    with_owners(#{}, fun() ->
        Link = start(self()),
        Tag = admitted(Link),
        Link ! {window, {withdraw, Tag}},
        ?assertEqual({outcome, Tag, {failed, withdrawn}}, told(erx_bt_fs)),
        ?assertEqual([16#08], [Code || <<_:16, 6:16/little, 16#05, Code>> <- sent()]),
        ?assertEqual(nothing, next(erx_bt_store))
    end).

%% A link killed mid-pairing is seen by each owner that monitors its pid, the pid its
%% messages came from, as a 'DOWN'; the link itself tells nobody of its end.
killed_link_is_seen_through_down_test() ->
    with_owners(#{}, fun() ->
        Link = start(self()),
        phone(Link, pairing_request()),
        {From, {admit, _Tag, ?CENTRAL}} = addressed(erx_bt_fs),
        Monitor = monitor(process, From),
        exit(Link, kill),
        ?assertEqual(killed, receive {'DOWN', Monitor, process, Link, R} -> R after ?WAIT_MS -> error(no_down) end),
        ?assertEqual(nothing, next(erx_bt_fs))
    end).

%% A link whose address resolved to a kept bond answers the Long Term Key Request with the
%% bond's key. Before its encryption the bond's subscription is not the link's, so a
%% notification is refused; at the controller's report the registry hears it bonded and the
%% subscription restored, and the notification, a request the registry sends, goes out.
%% sys:get_status/1 shows no key. At its start the link asks the window for the pairing
%% wait, and at `{wait, 0}` sends the Security Request, AuthReq bonding, MITM and SC for the
%% authenticated bond (Part H, 3.5.1, 3.6.7).
reconnection_with_a_kept_bond_test() ->
    with_owners(#{bond => ?BOND}, fun() ->
        Link = start(self()),
        ?assertEqual({Link, wait}, addressed(erx_bt_fs)),
        Link ! {window, {wait, 0}},
        ?assertEqual([frame(6, <<16#0B, 16#0D>>)], sent()),
        Notify = fun() -> gen_server:receive_response(gen_server:send_request(Link, {notify, notify, {svc, n}, <<"x">>}),
                                                      ?WAIT_MS) end,
        ?assertEqual({reply, {error, not_subscribed}}, Notify()),
        hci(Link, {le_long_term_key_request, 16#40, <<0:64>>, 0}),
        ?assertEqual({ltk_reply, ?BOND_LTK}, from_link()),
        hci(Link, {ltk_reply_complete, ok}),
        hci(Link, {encryption_change, 0, 16#40, 1}),
        ?assertEqual({security, #{level => authenticated, bonded => true, identity => ?CENTRAL}}, told(erx_gatt_srv)),
        ?assertEqual({subscribed, {svc, n}, notify}, told(erx_gatt_srv)),
        ?assertEqual({reply, ok}, Notify()),
        ?assertMatch([<<_:16, 4:16/little, 16#1B, _:16, "x">>], sent()),
        ?assertNot(holds(sys:get_status(Link), [?BOND_LTK])),
        exit(Link, kill),
        ?assertMatch({error, {_, Link}}, Notify())
    end).

%% A raise in the core mid-pairing, once the link holds the pairing's LTK and the Security
%% Manager its private key, passkey and DHKey: neither sys:get_status/1 before it, nor
%% the link's exit reason, nor any report logged shows a secret.
crash_mid_pairing_leaks_nothing_test() ->
    with_owners(#{}, fun() ->
        ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
        try
            Link = start(self()),
            {PhonePdus, Ltk} = just_works(),
            Tag = admitted(Link),
            [phone(Link, Pdu) || Pdu <- PhonePdus],
            Secrets = [Ltk, own_private(), dhkey(), ?PASSKEY],
            ?assertNot(holds(sys:get_status(Link), Secrets)),
            Link ! {window, {admission, Tag}},        % no clause of the core takes it
            Reason = receive {'EXIT', Link, R} -> R after ?WAIT_MS -> error(link_not_ended) end,
            ?assertMatch({step_raised, error, #{key := unauthenticated}}, Reason),
            timer:sleep(100),
            Logged = logged(),
            ?assertNotEqual([], Logged),
            ?assertNot(holds(Logged, Secrets)),
            lists:foreach(fun formatted/1, Logged)
        after
            logger:remove_handler(?MODULE)
        end
    end).

%% format_status/1 shows a message that carries the window's fresh values, and the sys
%% log that holds it, without them: the case erXos's report filter and OTP's own crash
%% reports both rely on when the verdict itself is the last message.
format_status_hides_the_verdict_test() ->
    with_owners(#{}, fun() ->
        Link = start(self()),
        Verdict = {window, {admission, 1, {open, nodisplay, fresh()}}},
        Status = erx_bt_link:format_status(#{state => sys:get_state(Link), message => Verdict,
                                             log => [{in, Verdict}], reason => normal}),
        ?assertMatch(#{message := {window, admission}, log := []}, Status),
        ?assertNot(holds(Status, [own_private(), ?PASSKEY]))
    end).

%% The handler's deadline runs on the wake-up timer: a write the handler never answers is
%% answered Unlikely Error (0x0E) 5 s after it arrived, and not before.
handler_deadline_on_the_timer_test_() ->
    {timeout, 20, fun() ->
        with_owners(#{}, fun() ->
            Link = start(self()),
            Handle = handle(open_w),
            phone_att(Link, <<16#12, Handle:16/little, "hi">>),
            ?assertMatch({write, _Ref, {svc, open_w}, <<"hi">>}, told(erx_gatt_srv)),
            Unlikely = <<5:16/little, 4:16/little, 16#01, 16#12, Handle:16/little, 16#0E>>,
            receive {erx_bt_link, ?NAME, {send, _, Unlikely}} -> error(answered_early) after 4500 -> ok end,
            receive {erx_bt_link, ?NAME, {send, _, Unlikely}} -> ok after 1500 -> error(not_answered) end
        end)
    end}.

%% ---- the stand-ins ----

%% Runs Case with the owners registered but those `absent` names, then ends them and any
%% link still running, waiting for each end so the names are free for the next case.
with_owners(Options, Case) ->
    process_flag(trap_exit, true),
    Test = self(),
    Owners = [begin
                  Pid = spawn_link(fun() -> stand_in(Name, Test, Options) end),
                  true = register(Name, Pid),
                  Pid
              end || Name <- [erx_bt_fs, erx_gatt_srv, erx_bt_store] -- maps:get(absent, Options, [])],
    try Case()
    after
        {links, Linked} = process_info(self(), links),
        Links = [Pid || Pid <- Linked, is_pid(Pid), proc_lib:initial_call(Pid) =:= {erx_bt_link, init, ['Argument__1']}],
        lists:foreach(fun end_process/1, Owners ++ Links),
        flush_owners()
    end.

%% What the owners forwarded and the case did not read, so the next case starts with none.
flush_owners() ->
    receive {owner, _Name, _Link, _Message} -> flush_owners()
    after 0 -> ok
    end.

end_process(Pid) ->
    Monitor = monitor(process, Pid),
    unlink(Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok end.

%% The store answers `resolve` with the case's bond, the registry `join` with the table;
%% with `hold`, each hands the call to the case to answer instead.
stand_in(Name, Test, Options) ->
    receive
        {'$gen_call', From, {resolve, _Address}} when Name =:= erx_bt_store ->
            answer(Name, From, maps:get(bond, Options, none), Test, Options);
        {'$gen_call', From, {join, _Conn, #{address := ?CENTRAL}}} when Name =:= erx_gatt_srv ->
            answer(Name, From, #{table => table(), values => #{}}, Test, Options);
        {erx_bt_link, Link, Message} ->
            Test ! {owner, Name, Link, Message}
    end,
    stand_in(Name, Test, Options).

answer(Name, From, Answer, Test, #{hold := true}) -> Test ! {held, Name, From, Answer};
answer(_Name, From, Answer, _Test, _Options) -> gen_server:reply(From, Answer).

held(Name) ->
    receive {held, Name, _, _} = Held -> Held after ?WAIT_MS -> error({not_called, Name}) end.

%% A link started by `Hci` as its controller process.
start(Hci) ->
    {ok, Link} = erx_bt_link:start_link(
                   #{name => ?NAME, conn => make_ref(), hci => Hci,
                     info => #{peer => ?CENTRAL, identity => ?OWN_ADDRESS, share => 16, acl_tx_max => 251}}),
    Link.

hci(Link, Input) -> erx_bt_link:hci(Link, Input).

%% A basic frame (Part A, 3.1) in one ACL packet, flagged first_flushable (Vol 4 Part E, 5.4.2).
frame(Cid, Payload) -> <<(byte_size(Payload)):16/little, Cid:16/little, Payload/binary>>.
phone(Link, SmpPdu) -> hci(Link, {acl, 2, frame(6, SmpPdu)}).
phone_att(Link, AttPdu) -> hci(Link, {acl, 2, frame(4, AttPdu)}).

%% The phone's Pairing Request and the window's `open` verdict for it, sent to the pid the
%% link's `admit` came from.
admitted(Link) ->
    phone(Link, pairing_request()),
    {Link, {admit, Tag, ?CENTRAL}} = addressed(erx_bt_fs),
    Link ! {window, {admission, Tag, {open, nodisplay, fresh()}}},
    Tag.

%% The next message the link sent the owner `Name`, with the pid it came from.
addressed(Name) ->
    receive {owner, Name, Link, Message} -> {Link, Message}
    after ?WAIT_MS -> error({nothing_to, Name})
    end.

told(Name) -> element(2, addressed(Name)).

%% Whether the link sent the owner `Name` anything more, within a short wait.
next(Name) ->
    receive {owner, Name, _Link, Message} -> Message
    after 200 -> nothing
    end.

%% The next request to the controller process that is not a packet.
from_link() ->
    receive {erx_bt_link, ?NAME, Request} when element(1, Request) =/= send -> Request
    after ?WAIT_MS -> error(no_request)
    end.

%% The packets the link has handed over so far.
sent() ->
    receive {erx_bt_link, ?NAME, {send, _Boundary, Data}} -> [Data | sent()]
    after 100 -> []
    end.

%% ---- the reports ----

%% The logger handler: every event logged reaches the case.
log(Event, #{config := #{test := Test}}) -> Test ! {logged, Event}.

logged() ->
    receive {logged, Event} -> [Event | logged()]
    after 0 -> []
    end.

%% A logged report as its own callback formats it, which raises when format_status/1 hands
%% gen_server's formatter a shape it does not take.
formatted(#{msg := {report, Report}, meta := #{report_cb := Format}}) when is_function(Format, 2) ->
    Format(Report, #{});
formatted(#{msg := {report, Report}, meta := #{report_cb := Format}}) when is_function(Format, 1) ->
    {Text, Args} = Format(Report),
    io_lib:format(Text, Args);
formatted(_Event) ->
    ok.

%% Whether a secret occurs anywhere in a term, inside a binary included.
holds(Term, Secrets) -> lists:any(fun(Secret) -> occurs(Secret, Term) end, Secrets).

occurs(Secret, Secret) -> true;
occurs(Secret, Term) when is_binary(Secret), is_binary(Term) -> binary:match(Term, Secret) =/= nomatch;
occurs(Secret, Term) when is_tuple(Term) -> occurs(Secret, tuple_to_list(Term));
occurs(Secret, Term) when is_map(Term) -> occurs(Secret, maps:to_list(Term));
occurs(Secret, [Head | Tail]) -> occurs(Secret, Head) orelse occurs(Secret, Tail);
occurs(_Secret, _Term) -> false.

%% ---- the table and the pairing ----

services() ->
    [#{name => svc, uuid => <<16#00, 16#FF>>,
       characteristics => [#{name => open_w, uuid => <<16#01, 16#FF>>, max => 20, access => #{write => open}},
                           #{name => n, uuid => <<16#02, 16#FF>>, max => 20, access => #{notify => open}}]}].

table() -> erx_gatt_db:build(?GAP, services()).

handle(Char) -> {ok, #{value := Handle}} = erx_gatt_db:characteristic({svc, Char}, table()), Handle.

%% SMP's Pairing Request (Part H, 3.5.1): NoInputNoOutput, no OOB, bonding, MITM, Secure
%% Connections and CT2, a 16-octet key, every key offered.
pairing_request() -> <<16#01, 16#03, 0, 16#2D, 16, 16#0B, 16#0B>>.

%% The phone's Identity Information and Identity Address Information (Part H, 3.6.4, 3.6.5).
identity() -> [<<16#08, 7:128>>, <<16#09, 1, 16#C6, 16#C5, 16#C4, 16#C3, 16#C2, 16#C1>>].

key(Seed) ->
    {<<4, X:32/binary, Y:32/binary>>, Private} = crypto:generate_key(ecdh, secp256r1, crypto:hash(sha256, <<Seed>>)),
    {Private, {X, Y}}.

nonces(Seed) -> [crypto:hash(md5, <<Seed, I>>) || I <- lists:seq(1, 20)].

%% The window's fresh values: the link's private key, its nonces and a passkey.
fresh() ->
    {Private, Public} = key(1),
    #{private => Private, public => Public, nonces => nonces(1), passkey => ?PASSKEY}.

own_private() -> element(1, key(1)).

dhkey() -> erx_smp_crypto:dhkey(element(1, key(2)), element(2, key(1))).

%% The honest phone's Just Works PDUs after its Pairing Request (Part H, 2.3.5.6.2 and
%% 2.3.5.6.5, 3.5 and 3.6), computed independently with erx_smp_crypto, and the LTK.
just_works() ->
    {_PhonePrivate, {X, Y}} = key(2),
    [Na | _] = nonces(2),
    [Nb | _] = nonces(1),
    {MacKey, Ltk} = erx_smp_crypto:f5(dhkey(), Na, Nb, ?CENTRAL, ?PERIPHERAL),
    Ea = erx_smp_crypto:f6(MacKey, Na, Nb, <<0:128>>, <<16#2D, 0, 16#03>>, ?CENTRAL, ?PERIPHERAL),
    {[<<16#0C, (rev(X))/binary, (rev(Y))/binary>>, <<16#04, (rev(Na))/binary>>, <<16#0D, (rev(Ea))/binary>>], Ltk}.

rev(Bytes) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).
