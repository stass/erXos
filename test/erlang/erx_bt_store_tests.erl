%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the Bluetooth store (docs/design-bluetooth.md, "Bonds and the store" and
%% "Host tests of the cores"): erx_bt_state's layout, erx_bt_state_file over a directory
%% of its own, and erx_bt_store against a scripted backend, a process that holds the
%% medium's newest blob and its generation and answers each get and put as the case scripts it (read or write,
%% unavailable, a blob that does not decode, a put that reaches the medium and answers
%% unavailable, no answer at all). Processes registered as the window (erx_bt_fs) and
%% spawned as links forward what the store sends them. The store's table is explored
%% over every start state, request, put answer and read answer, and run over the
%% development file with a put the storage completes after the store's deadline and with
%% its rename failing; the file's modes and its order of rename, directory sync and
%% deletions are checked over a directory of its own.

-module(erx_bt_store_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").
-include_lib("kernel/include/file.hrl").
-define(GAP, #{name => <<"erxos">>, appearance => 0}).

-define(ADDRESS, <<2#11:2, 7:46>>).

%% ---------------------------------------------------------------- erx_bt_state

bond(N) ->
    #{id => id(N), identity => {public, <<0, 0, 0, 0, 0, N>>}, irk => <<(16#1000 + N):128>>, ltk => <<(16#2000 + N):128>>,
      level => authenticated, hash => <<>>, subscriptions => #{}}.

%% The id of bond N, as a counter would make it.
id(N) -> binary:encode_hex(<<N:128>>, lowercase).

state(Bonds) -> #{address => ?ADDRESS, bonds => Bonds}.

blob(Bonds) ->
    {ok, Blob} = erx_bt_state:encode(state(Bonds)),
    Blob.

%% A blob of the bonds each encoded alone, as no encoder writes a state that breaks a rule
%% over two bonds.
joined(Bonds) ->
    iolist_to_binary([2, ?ADDRESS, length(Bonds) | [binary:part(B, 8, byte_size(B) - 8) || B <- [blob([Bd]) || Bd <- Bonds]]]).

state_round_trips_test() ->
    Full = (bond(1))#{identity := {random, <<2#11:2, 5:46>>}, level := unauthenticated, hash := <<9:256>>,
                      subscriptions := #{{<<"nus">>, <<"tx">>} => notify, {<<"hid">>, <<"report_1">>} => indicate}},
    State = state([Full, bond(2)]),
    {ok, Blob} = erx_bt_state:encode(State),
    ?assertEqual({ok, State}, erx_bt_state:decode(Blob)),
    ?assertEqual({ok, state([])}, erx_bt_state:decode(blob([]))).

state_refuses_another_version_test() ->
    <<_, Rest/binary>> = blob([bond(1)]),
    ?assertEqual({error, {version, 1}}, erx_bt_state:decode(<<1, Rest/binary>>)),
    ?assertEqual({error, {version, 3}}, erx_bt_state:decode(<<3, Rest/binary>>)),
    ?assertEqual({error, empty}, erx_bt_state:decode(<<>>)).

state_refuses_every_truncation_and_trailing_octet_test() ->
    Blob = blob([(bond(1))#{hash := <<1:256>>, subscriptions := #{{<<"nus">>, <<"tx">>} => notify}}, bond(2)]),
    [?assertMatch({error, _}, erx_bt_state:decode(binary:part(Blob, 0, N))) || N <- lists:seq(0, byte_size(Blob) - 1)],
    ?assertEqual({error, trailing}, erx_bt_state:decode(<<Blob/binary, 0>>)).

state_refuses_oversized_count_test() ->
    Nine = [bond(N) || N <- lists:seq(1, 9)],
    Blob = iolist_to_binary([2, ?ADDRESS, 9, [binary:part(B, 8, byte_size(B) - 8) || B <- [blob([Bd]) || Bd <- Nine]]]),
    ?assertEqual({error, {too_many_bonds, 9}}, erx_bt_state:decode(Blob)),
    ?assertEqual({error, too_large}, erx_bt_state:encode(state(Nine))).

state_refuses_malformed_fields_test() ->
    One = blob([bond(1)]),
    Field = fun(Offset, Octet) -> <<Head:Offset/binary, _, Tail/binary>> = One, <<Head/binary, Octet, Tail/binary>> end,
    ?assertEqual({error, identity}, erx_bt_state:decode(Field(8 + 16, 2))),
    ?assertEqual({error, {level, 2}}, erx_bt_state:decode(Field(8 + 16 + 39, 2))),
    ?assertEqual({error, {hash_length, 31}}, erx_bt_state:decode(Field(8 + 16 + 40, 31))),
    ?assertEqual({error, header}, erx_bt_state:decode(<<2, 2#11:2, 7:46>>)),
    ?assertEqual({error, address}, erx_bt_state:decode(<<2, 0:48, 0>>)),
    ?assertEqual({error, address}, erx_bt_state:decode(<<2, 2#11:2, (1 bsl 46 - 1):46, 0>>)),
    Private = (bond(1))#{identity := {random, <<2#01:2, 5:46>>}},
    ?assertEqual({error, identity}, erx_bt_state:decode(blob([Private]))),
    AllOnes = (bond(1))#{identity := {random, <<2#11:2, (1 bsl 46 - 1):46>>}},
    ?assertEqual({error, identity}, erx_bt_state:decode(blob([AllOnes]))),
    Again = (bond(1))#{id := id(9)},
    ?assertEqual({error, duplicate_identity}, erx_bt_state:encode(state([bond(1), Again]))),
    ?assertEqual({error, duplicate_identity}, erx_bt_state:decode(joined([bond(1), Again]))),
    Two = blob([(bond(1))#{subscriptions := #{{<<"a">>, <<"x">>} => notify, {<<"b">>, <<"y">>} => notify}}]),
    Swapped = binary:replace(Two, <<1, 1, $a, 1, $x, 1, 1, $b, 1, $y>>, <<1, 1, $b, 1, $y, 1, 1, $a, 1, $x>>),
    ?assertEqual({error, subscription_order}, erx_bt_state:decode(Swapped)),
    Bad = (bond(1))#{subscriptions := #{{<<"Nus">>, <<"tx">>} => notify}},
    ?assertEqual({error, name}, erx_bt_state:decode(blob([Bad]))),
    ?assertEqual({error, too_large}, erx_bt_state:decode(<<One/binary, 0:(8 * ?ERX_BT_STATE_MAX)>>)).

%% No two bonds share an id: the encoder refuses such a state, and the decoder refuses a
%% blob that holds one; a public and a random identity of the same octets are two bonds.
state_refuses_a_shared_id_test() ->
    Twin = (bond(2))#{id := id(1)},
    ?assertEqual({error, duplicate_id}, erx_bt_state:encode(state([bond(1), Twin]))),
    ?assertEqual({error, duplicate_id}, erx_bt_state:decode(joined([bond(1), Twin]))),
    Octets = <<16#C0, 0, 0, 0, 0, 1>>,
    Both = state([(bond(1))#{identity := {public, Octets}}, (bond(2))#{identity := {random, Octets}}]),
    ?assertEqual({ok, Both}, erx_bt_state:decode(blob(maps:get(bonds, Both)))).

%% The largest state the served table lets the store write fits `bt_state_max`: a bond's
%% subscriptions are its link's, so they name only characteristics of the table, each
%% with a configuration attribute, and the table is every service abi/gatt declares, as
%% erx_bt_sup serves it, with GAP's and GATT's own. So `bt_bonds_max` bonds, each with a
%% table hash and subscribed to every such characteristic, are the largest state, and a
%% declaration that would make a put `too_large` fails here.
state_largest_fits_test() ->
    Table = erx_gatt_db:build(?GAP, [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()]),
    Subs = #{{atom_to_binary(Service), atom_to_binary(Char)} => indicate
             || #{source := {configuration, {Service, Char}}} <- erx_gatt_db:range(1, 16#ffff, Table)},
    %% Every table holds GATT's Service Changed, so a pattern that stopped matching fails.
    ?assert(is_map_key({<<"gatt">>, <<"service_changed">>}, Subs)),
    Bonds = [(bond(N))#{hash := <<N:256>>, subscriptions := Subs} || N <- lists:seq(1, ?ERX_BT_BONDS_MAX)],
    {ok, Blob} = erx_bt_state:encode(state(Bonds)),
    ?assert(byte_size(Blob) =< ?ERX_BT_STATE_MAX).

%% ---------------------------------------------------------------- erx_bt_state_file

state_file_test() ->
    Root = string:trim(os:cmd("mktemp -d")),
    Dir = filename:join(Root, "bt"),
    ?assertEqual({error, unavailable}, erx_bt_state_file:get(filename:join([Root, "absent", "bt"]))),
    ?assertEqual({ok, 0, none}, erx_bt_state_file:get(Dir)),
    ?assertEqual(ok, erx_bt_state_file:put(Dir, 1, <<"one">>)),
    ?assertEqual({ok, 1, <<"one">>}, erx_bt_state_file:get(Dir)),
    %% A put of a lower generation that lands after a higher one is never read.
    ?assertEqual(ok, erx_bt_state_file:put(Dir, 3, <<"three">>)),
    ?assertEqual(ok, erx_bt_state_file:put(Dir, 2, <<"two">>)),
    ?assertEqual({ok, 3, <<"three">>}, erx_bt_state_file:get(Dir)),
    %% A put's .new name counts in the generation get answers; no other name is read.
    ok = file:write_file(filename:join(Dir, "bonds.7.new"), <<"half">>),
    [ok = file:write_file(filename:join(Dir, Name), <<"x">>) || Name <- ["bonds.09", "bonds.9.old", "bonds.", "notes"]],
    ?assertEqual({ok, 7, <<"three">>}, erx_bt_state_file:get(Dir)),
    %% Once its own file is in place a put deletes every lower name, and no other.
    ?assertEqual(ok, erx_bt_state_file:put(Dir, 8, <<"eight">>)),
    {ok, Left} = file:list_dir(Dir),
    ?assertEqual(["bonds.", "bonds.09", "bonds.8", "bonds.9.old", "notes"], lists:sort(Left)),
    %% A put whose .new name another put holds fails, and leaves the newest.
    ok = file:write_file(filename:join(Dir, "bonds.9.new"), <<"other">>),
    ?assertEqual({error, unavailable}, erx_bt_state_file:put(Dir, 9, <<"nine">>)),
    ?assertEqual({ok, <<"other">>}, file:read_file(filename:join(Dir, "bonds.9.new"))),
    ?assertEqual({ok, 9, <<"eight">>}, erx_bt_state_file:get(Dir)),
    %% A newest file that cannot be read answers as a blob that does not decode.
    ok = file:make_dir(filename:join(Dir, "bonds.11")),
    ?assertEqual({ok, 11, <<>>}, erx_bt_state_file:get(Dir)),
    ok = file:del_dir(filename:join(Dir, "bonds.11")),
    ok = file:write_file(filename:join(Dir, "bonds.10"), binary:copy(<<0>>, 2 * ?ERX_BT_STATE_MAX)),
    {ok, 10, Big} = erx_bt_state_file:get(Dir),
    ?assertEqual(?ERX_BT_STATE_MAX + 1, byte_size(Big)),
    ?assertEqual({error, unavailable}, erx_bt_state_file:put(filename:join([Root, "absent", "bt"]), 1, <<"x">>)),
    os:cmd("rm -rf " ++ Root).

%% A put syncs the directory once its rename is in place and before it deletes a lower
%% name, so the rename reaches the medium before the put answers ok and before any
%% deletion does. The put's calls of `file` are traced: after the rename the directory
%% is opened with `directory` and synced, and only then is `bonds.1` deleted.
state_file_syncs_directory_after_rename_test() ->
    Root = string:trim(os:cmd("mktemp -d")),
    Dir = filename:join(Root, "bt"),
    ok = erx_bt_state_file:put(Dir, 1, <<"one">>),
    Tracer = spawn_link(fun() -> traced_calls([]) end),
    erlang:trace_pattern({file, '_', '_'}, true, [local]),
    erlang:trace(self(), true, [call, {tracer, Tracer}]),
    Put = try erx_bt_state_file:put(Dir, 2, <<"two">>)
          after
              erlang:trace(self(), false, [call]),
              erlang:trace_pattern({file, '_', '_'}, false, [local])
          end,
    Delivered = erlang:trace_delivered(self()),
    receive {trace_delivered, _, Delivered} -> ok end,
    Tracer ! {calls, self()},
    Calls = receive {calls, Traced} -> Traced end,
    os:cmd("rm -rf " ++ Root),
    ?assertEqual(ok, Put),
    Lower = filename:join(Dir, "bonds.1"),
    {BeforeOpen, Opened} = lists:splitwith(fun(Call) -> Call =/= {open, [Dir, [read, directory]]} end, Calls),
    {BeforeSync, Synced} = lists:splitwith(fun({Function, _}) -> Function =/= sync end, Opened),
    ?assertNotEqual([], Synced),
    ?assert(lists:keymember(rename, 1, BeforeOpen)),
    ?assertNot(lists:member({delete, [Lower]}, BeforeOpen ++ BeforeSync)),
    ?assert(lists:member({delete, [Lower]}, Synced)).

%% The traced process is not its own tracer, so a process of its own collects the calls.
traced_calls(Calls) ->
    receive
        {trace, _, call, {file, Function, Args}} -> traced_calls([{Function, Args} | Calls]);
        {calls, Asker} -> Asker ! {calls, lists:reverse(Calls)}
    end.

state_file_names_test() ->
    ?assertEqual({state, 12}, erx_bt_state_file:generation("bonds.12")),
    ?assertEqual({new, 1}, erx_bt_state_file:generation("bonds.1.new")),
    [?assertEqual(other, erx_bt_state_file:generation(Name))
     || Name <- ["bonds.0", "bonds.012", "bonds.1000000000000000000", "bonds.", "bonds.1.old", "bonds.1.new.new", "bonds.-1", "bonds.1x",
                 "bonds." ++ [16#661], "state", <<"bonds.1">>, [$b | improper]]].

%% ---------------------------------------------------------------- the store

%% The scripted backend: Gets and Puts are the answers in order, then `read` and `ok`. Its
%% medium keeps the blob of the highest generation put, as the seam promises; a scripted
%% blob is generation 1.
script(Medium, Gets, Puts) ->
    Generation = case Medium of none -> 0; _ -> 1 end,
    spawn(fun() -> script_loop({Generation, Medium}, Gets, Puts) end).

script_loop({Generation, Medium} = Kept, Gets, Puts) ->
    receive
        {get, From} ->
            {Step, Rest} = next(Gets, read),
            case Step of
                read -> From ! {script, {ok, Generation, Medium}};
                unavailable -> From ! {script, {error, unavailable}};
                garbage -> From ! {script, {ok, Generation, <<"not a state">>}};
                hang -> ok
            end,
            script_loop(Kept, Rest, Puts);
        {put, Put, Blob, From} ->
            {Step, Rest} = next(Puts, ok),
            Landed = case Put > Generation of
                         true -> {Put, Blob};
                         false -> Kept
                     end,
            {Answer, Next} = case Step of
                                 ok -> {ok, Landed};
                                 lost -> {{error, unavailable}, Kept};
                                 landed -> {{error, unavailable}, Landed};
                                 too_large -> {{error, too_large}, Kept};
                                 hang -> {hang, Kept}
                             end,
            Answer =:= hang orelse (From ! {script, Answer}),
            script_loop(Next, Gets, Rest);
        {medium, From} ->
            From ! {script, Medium},
            script_loop(Kept, Gets, Puts)
    end.

next([Step | Rest], _Default) -> {Step, Rest};
next([], Default) -> {Default, []}.

ask(Script, Message) ->
    Script ! Message,
    receive {script, Answer} -> Answer end.

medium(Script) ->
    case ask(Script, {medium, self()}) of
        none -> none;
        Blob -> {ok, State} = erx_bt_state:decode(Blob), State
    end.

start(Medium, Gets, Puts) -> start(Medium, Gets, Puts, 500).

start(Medium, Gets, Puts, Timeout) -> start(Medium, Gets, Puts, Timeout, #{}).

start(Medium, Gets, Puts, Timeout, Options) ->
    Script = script(Medium, Gets, Puts),
    Backend = #{get => fun() -> ask(Script, {get, self()}) end,
                put => fun(Generation, Blob) -> ask(Script, {put, Generation, Blob, self()}) end},
    {start_backend(Backend, Timeout, Options), Script}.

start_backend(Backend, Timeout) -> start_backend(Backend, Timeout, #{}).

start_backend(Backend, Timeout, Options) ->
    Test = self(),
    is_pid(whereis(erx_bt_fs)) andalso exit(whereis(erx_bt_fs), kill),
    wait_unregistered(erx_bt_fs),
    register(erx_bt_fs, spawn(fun() -> forward(Test, window) end)),
    {ok, Store} = erx_bt_store:start_link(Options#{backend => Backend, timeout => Timeout}),
    unlink(Store),
    Store.

stop(Store) ->
    Monitor = monitor(process, Store),
    exit(Store, kill),
    receive {'DOWN', Monitor, _, _, _} -> ok end,
    flush().

flush() -> receive _ -> flush() after 0 -> ok end.

forward(Test, Tag) ->
    receive Message -> Test ! {Tag, self(), Message}, forward(Test, Tag) end.

%% A link stand-in that forwards what the store sends it.
fake_link() ->
    Test = self(),
    spawn(fun() -> forward(Test, link) end).

paired(N) -> maps:with([identity, irk, ltk, level], bond(N)).

keep(Link, N) ->
    erx_bt_store ! {erx_bt_link, Link, {keep, 7, paired(N), #{{nus, tx} => notify, {nus, rx} => none}}}.

kept(Link) ->
    receive {link, Link, {store, {kept, Answer}}} -> Answer after 7000 -> no_answer end.

outcome(Link) ->
    receive {window, _, {outcome, Link, 7, Outcome}} -> Outcome after 1000 -> no_outcome end.

identities(none) -> [];
identities(#{bonds := Bonds}) -> [Identity || #{identity := Identity} <- Bonds].

start_reading_none_makes_the_address_test() ->
    {Store, Script} = start(none, [], []),
    #{store := read, reason := none, bonds := [], address := <<2#11:2, _:46>> = Address} = erx_bt_store:facts(),
    ?assertEqual(read, erx_bt_store:known()),
    ?assertEqual(Address, erx_bt_store:address()),
    Link = fake_link(),
    keep(Link, 1),
    {ok, Id} = kept(Link),
    ?assertEqual(#{address => Address, bonds => [(bond(1))#{id := Id, subscriptions := #{{<<"nus">>, <<"tx">>} => notify}}]},
                 medium(Script)),
    stop(Store).

start_reading_a_state_takes_its_address_and_bonds_test() ->
    {Store, _} = start(blob([bond(1)]), [], []),
    ?assertMatch(#{store := read, address := ?ADDRESS, bonds := [{{public, <<0, 0, 0, 0, 0, 1>>}, authenticated}]},
                 erx_bt_store:facts()),
    stop(Store).

%% A start that cannot read runs without bonds and refuses every change but `forget all`,
%% which replaces the blob under the address in use.
start_unreadable_refuses_changes_until_forget_all_test_() ->
    [fun() -> start_unread(Get, Reason) end || {Get, Reason} <- [{unavailable, store_unavailable},
                                                                {garbage, store_unreadable}]].

start_unread(Get, Reason) ->
    {Store, Script} = start(blob([bond(1)]), [Get], []),
    #{store := unknown, reason := Reason, bonds := [], address := Address} = erx_bt_store:facts(),
    ?assertNotEqual(?ADDRESS, Address),
    ?assertEqual({unknown, start}, erx_bt_store:known()),
    ?assertEqual(none, erx_bt_store:resolve({public, <<0, 0, 0, 0, 0, 1>>})),
    Link = fake_link(),
    keep(Link, 2),
    ?assertEqual({error, unavailable}, kept(Link)),
    ?assertEqual({failed, unavailable}, outcome(Link)),
    ?assertEqual({error, eio}, erx_bt_store:forget(identity(1))),
    ?assertEqual([{public, <<0, 0, 0, 0, 0, 1>>}], identities(medium(Script))),
    ?assertEqual(ok, erx_bt_store:forget(all)),
    ?assertEqual(#{address => Address, bonds => []}, medium(Script)),
    ?assertMatch(#{store := read, reason := none}, erx_bt_store:facts()),
    ?assertEqual(read, erx_bt_store:known()),
    stop(Store).

%% A put that reached the medium and answered unavailable fails its pairing; the next
%% pairing reads first and keeps both bonds.
unconfirmed_put_reads_before_the_next_change_test() ->
    {Store, Script} = start(blob([]), [], [landed]),
    First = fake_link(),
    keep(First, 1),
    ?assertEqual({error, unavailable}, kept(First)),
    ?assertEqual({failed, unavailable}, outcome(First)),
    ?assertMatch(#{store := unknown, reason := store_unavailable, bonds := []}, erx_bt_store:facts()),
    ?assertEqual({unknown, put}, erx_bt_store:known()),
    Second = fake_link(),
    keep(Second, 2),
    ?assertMatch({ok, <<_:256>>}, kept(Second)),
    ?assertEqual([identity(1), identity(2)], identities(medium(Script))),
    ?assertEqual(identities(medium(Script)), [I || {I, _} <- maps:get(bonds, erx_bt_store:facts())]),
    ?assertEqual(read, erx_bt_store:known()),
    stop(Store).

identity(N) -> maps:get(identity, bond(N)).

keep_of_a_dead_link_still_reaches_the_window_test() ->
    {Store, Script} = start(none, [], []),
    Link = spawn(fun() -> ok end),
    Monitor = monitor(process, Link),
    receive {'DOWN', Monitor, _, _, _} -> ok end,
    keep(Link, 1),
    ?assertMatch({bonded, <<_:256>>, {public, <<0, 0, 0, 0, 0, 1>>}, authenticated}, outcome(Link)),
    ?assertEqual([identity(1)], identities(medium(Script))),
    ?assertMatch(#{links := 0}, erx_bt_store:facts()),
    stop(Store).

keep_refuses_a_kept_identity_and_a_ninth_bond_test() ->
    {Store, Script} = start(blob([bond(N) || N <- lists:seq(1, 8)]), [], []),
    Link = fake_link(),
    keep(Link, 3),
    ?assertEqual({error, already_bonded}, kept(Link)),
    ?assertEqual({failed, already_bonded}, outcome(Link)),
    keep(Link, 9),
    ?assertEqual({error, bonds_full}, kept(Link)),
    ?assertEqual({failed, bonds_full}, outcome(Link)),
    ?assertEqual(8, length(identities(medium(Script)))),
    stop(Store).

%% A resolvable private address with the top bits 01, prand above and ah(IRK, prand) below.
private_address(Irk, Prand) ->
    {random, <<Prand/binary, (erx_smp_crypto:ah(Irk, Prand))/binary>>}.

resolve_answers_one_bond_without_any_irk_test() ->
    Zero = (bond(3))#{irk := <<0:128>>},
    Subscribed = (bond(2))#{hash := <<5:256>>, subscriptions := #{{<<"nus">>, <<"tx">>} => indicate,
                                                                  {<<"no_such_service_zz">>, <<"tx">>} => notify}},
    {Store, _} = start(blob([bond(1), Subscribed, Zero]), [], []),
    #{irk := Irk2} = Subscribed,
    Prand = <<2#01:2, 12345:22>>,
    Answer = erx_bt_store:resolve(private_address(Irk2, Prand)),
    ?assertEqual(#{id => id(2), ltk => maps:get(ltk, Subscribed), level => authenticated, identity => identity(2),
                   hash => <<5:256>>, subscriptions => #{{nus, tx} => indicate}}, Answer),
    ?assertEqual(Answer, erx_bt_store:resolve(identity(2))),
    ?assertEqual(none, erx_bt_store:resolve(private_address(<<0:128>>, Prand))),
    ?assertEqual(none, erx_bt_store:resolve({random, <<Prand/binary, 0:24>>})),
    ?assertEqual(none, erx_bt_store:resolve({random, <<0, 0, 0, 0, 0, 2>>})),
    Wire = term_to_binary(Answer),
    [?assertEqual(nomatch, binary:match(Wire, Irk)) || #{irk := Irk} <- [bond(1), Subscribed, Zero], Irk =/= <<0:128>>],
    stop(Store).

%% Forgetting a bond ends the link whose address resolved to it at its start.
forget_ends_the_links_of_that_bond_test() ->
    {Store, Script} = start(blob([bond(1), bond(2)]), [], []),
    Test = self(),
    Resolver = fun(N) -> spawn(fun() -> _ = erx_bt_store:resolve(identity(N)), forward(Test, link) end) end,
    One = Resolver(1),
    Two = Resolver(2),
    wait_links(2),
    ?assertEqual({error, enoent}, erx_bt_store:forget(identity(9))),
    ?assertEqual(ok, erx_bt_store:forget(identity(1))),
    receive {link, One, {store, forgotten}} -> ok after 2000 -> error(not_forgotten) end,
    receive {link, Two, {store, forgotten}} -> error(other_forgotten) after 100 -> ok end,
    ?assertEqual([identity(2)], identities(medium(Script))),
    ?assertMatch(#{links := 1}, erx_bt_store:facts()),
    exit(Two, kill),
    wait_links(0),
    stop(Store).

%% A bond's identity is its type with its octets: forgetting the public address leaves
%% the random one of the same octets, and a type no bond has is `enoent`.
forget_matches_the_whole_identity_test() ->
    Octets = <<16#C0, 0, 0, 0, 0, 1>>,
    Public = (bond(1))#{identity := {public, Octets}},
    Random = (bond(2))#{identity := {random, Octets}},
    {Store, Script} = start(blob([Random, Public]), [], []),
    ?assertEqual({error, enoent}, erx_bt_store:forget({random, <<16#C0, 0, 0, 0, 0, 2>>})),
    ?assertEqual(ok, erx_bt_store:forget({public, Octets})),
    ?assertEqual([{random, Octets}], identities(medium(Script))),
    ?assertEqual({error, enoent}, erx_bt_store:forget({public, Octets})),
    stop(Store).

%% A kept bond's id (docs/design-bluetooth.md, "A bond's name is made with its key"): 32
%% lower-case hexadecimal digits, given alike by the link's `kept`,
%% the window's outcome and `resolve/1`; drawn afresh for the same phone after a forget;
%% forgotten by it, `enoent` once gone.
bond_id_is_drawn_at_keep_test() ->
    {Store, Script} = start(none, [], []),
    Pair = fun() ->
                   Link = fake_link(),
                   keep(Link, 1),
                   {ok, Id} = kept(Link),
                   ?assertEqual({bonded, Id, identity(1), authenticated}, outcome(Link)),
                   Id
           end,
    First = Pair(),
    ?assertMatch({match, _}, re:run(First, "^[0-9a-f]{32}$")),
    ?assertMatch(#{id := First}, erx_bt_store:resolve(identity(1))),
    ?assertMatch(#{bonds := [#{id := First}]}, medium(Script)),
    ?assertEqual({error, enoent}, erx_bt_store:forget(id(0))),
    ?assertEqual(ok, erx_bt_store:forget(First)),
    ?assertEqual(none, erx_bt_store:resolve(identity(1))),
    ?assertEqual({error, enoent}, erx_bt_store:forget(First)),
    Second = Pair(),
    ?assertNotEqual(First, Second),
    ?assertMatch(#{id := Second}, erx_bt_store:resolve(identity(1))),
    stop(Store).

%% The state lost to a blob that does not decode held bond 1 under id 1; after `forget
%% all` the next bond's id is none it held, whatever the store now counts.
bond_id_owes_nothing_to_a_lost_state_test() ->
    {Store, _} = start(blob([bond(1)]), [garbage], []),
    ?assertEqual(ok, erx_bt_store:forget(all)),
    Link = fake_link(),
    keep(Link, 2),
    {ok, Id} = kept(Link),
    ?assertNotEqual(maps:get(id, bond(1)), Id),
    stop(Store).

%% A random source that repeats a kept bond's id once: the store draws again, and the
%% new bond is kept under a fresh id.
bond_id_drawn_again_on_a_clash_test() ->
    Source = fun() ->
                     case get(drawn) of
                         undefined -> put(drawn, once), <<1:128>>;
                         once -> crypto:strong_rand_bytes(16)
                     end
             end,
    {Store, Script} = start(blob([bond(1)]), [], [], 500, #{id_source => Source}),
    Link = fake_link(),
    keep(Link, 2),
    {ok, Id} = kept(Link),
    ?assertNotEqual(maps:get(id, bond(1)), Id),
    ?assertEqual([id(1), Id], [Kept || #{id := Kept} <- maps:get(bonds, medium(Script))]),
    stop(Store).

%% The two identities of one address (row 4127): a public and a random bond of the same
%% octets are two bonds with two ids.
two_identities_of_one_address_test() ->
    Octets = <<16#C0, 0, 0, 0, 0, 1>>,
    {Store, Script} = start(none, [], []),
    Pair = fun(Type) ->
                   Link = fake_link(),
                   erx_bt_store ! {erx_bt_link, Link, {keep, 7, (paired(1))#{identity := {Type, Octets}}, #{}}},
                   {ok, Id} = kept(Link),
                   Id
           end,
    Public = Pair(public),
    Random = Pair(random),
    ?assertNotEqual(Public, Random),
    ?assertEqual(ok, erx_bt_store:forget(Public)),
    ?assertEqual([{random, Octets}], identities(medium(Script))),
    ?assertEqual({error, enoent}, erx_bt_store:forget(Public)),
    ?assertMatch(#{id := Random}, erx_bt_store:resolve({random, Octets})),
    stop(Store).

wait_links(N) ->
    case erx_bt_store:facts() of
        #{links := N} -> ok;
        _ -> timer:sleep(10), wait_links(N)
    end.

subscriptions_and_served_change_the_links_bond_test() ->
    {Store, Script} = start(blob([bond(1)]), [], [ok, ok, lost]),
    Test = self(),
    Link = spawn(fun() -> _ = erx_bt_store:resolve(identity(1)), forward(Test, link) end),
    wait_links(1),
    erx_bt_store ! {erx_bt_link, Link, {subscriptions, #{{nus, tx} => indicate}}},
    ?assertEqual({ok, id(1)}, kept(Link)),
    erx_bt_store ! {erx_bt_link, Link, {served, <<3:256>>}},
    #{bonds := [Bond]} = (fun W() -> case medium(Script) of #{bonds := [#{hash := <<3:256>>}]} = M -> M;
                                                            _ -> timer:sleep(10), W() end end)(),
    ?assertEqual(#{{<<"nus">>, <<"tx">>} => indicate}, maps:get(subscriptions, Bond)),
    erx_bt_store ! {erx_bt_link, Link, {subscriptions, #{}}},
    ?assertEqual({error, unavailable}, kept(Link)),
    Stranger = fake_link(),
    erx_bt_store ! {erx_bt_link, Stranger, {subscriptions, #{}}},
    ?assertEqual({error, unavailable}, kept(Stranger)),
    stop(Store).

%% Every backend call ends at bt_store_timeout_ms itself: a get at the start, a put of a
%% pairing, whose window still hears the outcome.
backend_that_never_answers_test_() ->
    {timeout, 30, fun() ->
        T0 = erlang:monotonic_time(millisecond),
        {Hung, _} = start(blob([bond(1)]), [hang], [], ?ERX_BT_STORE_TIMEOUT_MS),
        ?assert(erlang:monotonic_time(millisecond) - T0 >= ?ERX_BT_STORE_TIMEOUT_MS),
        ?assertMatch(#{store := unknown, reason := store_unavailable}, erx_bt_store:facts()),
        stop(Hung),
        {Store, _} = start(blob([]), [], [hang], ?ERX_BT_STORE_TIMEOUT_MS),
        Link = fake_link(),
        keep(Link, 1),
        ?assertEqual({error, unavailable}, kept(Link)),
        ?assertEqual({failed, unavailable}, outcome(Link)),
        ?assertMatch(#{store := unknown, reason := store_unavailable}, erx_bt_store:facts()),
        stop(Store),
        %% A bonded link's configuration write: the store answers unavailable at its
        %% deadline, keeps the bond's subscriptions as they were and reads first next time.
        {Bonded, _} = start(blob([bond(1)]), [], [hang], 300),
        Test = self(),
        Writer = spawn(fun() -> _ = erx_bt_store:resolve(identity(1)), forward(Test, link) end),
        wait_links(1),
        erx_bt_store ! {erx_bt_link, Writer, {subscriptions, #{{nus, tx} => notify}}},
        ?assertEqual({error, unavailable}, kept(Writer)),
        ?assertMatch(#{store := unknown, reason := store_unavailable}, erx_bt_store:facts()),
        ?assertMatch(#{subscriptions := Kept} when map_size(Kept) =:= 0, erx_bt_store:resolve(identity(1))),
        stop(Bonded)
    end}.

%% Neither the status nor a raise's reason shows a key.
no_key_in_status_or_crash_test() ->
    {Store, _} = start(blob([bond(1), bond(2)]), [], []),
    Status = term_to_binary(sys:get_status(erx_bt_store)),
    Keys = lists:append([[Irk, Ltk] || #{irk := Irk, ltk := Ltk} <- [bond(1), bond(2)]]),
    [?assertEqual(nomatch, binary:match(Status, Key)) || Key <- Keys],
    Monitor = monitor(process, Store),
    erx_bt_store ! {erx_bt_link, self(), {keep, 1, paired(1), not_a_map}},
    Reason = receive {'DOWN', Monitor, _, _, R} -> R after 2000 -> no_exit end,
    ?assertMatch({shutdown, {raised, error, #{store := read}}}, Reason),
    [?assertEqual(nomatch, binary:match(term_to_binary(Reason), Key)) || Key <- Keys],
    flush().

%% The store's table, explored: every start state, request, put answer and read answer.
%% After each request the answer is the model's, and a read store's bonds are the
%% medium's.
explored_store_table_test_() ->
    {timeout, 120, fun() ->
        [explore(Known, Request, Put, Reread)
         || Known <- [read, unknown_start, unknown_put],
            Request <- [keep_new, keep_kept, forget_one, forget_missing, forget_all],
            Put <- [ok, lost, landed],
            Reread <- [read, unavailable, garbage]]
    end}.

explore(Known, Request, Put, Reread) ->
    {Gets, Puts} = case Known of
                       read -> {[], [Put]};
                       unknown_start -> {[unavailable], [Put]};
                       unknown_put -> {[read, Reread], [lost, Put]}
                   end,
    {Store, Script} = start(blob([bond(1)]), Gets, Puts),
    Known =:= unknown_put andalso begin L = fake_link(), keep(L, 9), {error, unavailable} = kept(L) end,
    Answer = request(Request),
    Expected = model(Known, Request, Put, Reread),
    Case = {Known, Request, Put, Reread},
    ?assertEqual({Case, Expected}, {Case, Answer}),
    #{store := Store1, bonds := Bonds} = erx_bt_store:facts(),
    Store1 =:= read andalso ?assertEqual({Case, identities(medium(Script))}, {Case, [I || {I, _} <- Bonds]}),
    stop(Store).

request(keep_new) -> L = fake_link(), keep(L, 2), unnamed(kept(L), outcome(L));
request(keep_kept) -> L = fake_link(), keep(L, 1), unnamed(kept(L), outcome(L));
request(forget_one) -> erx_bt_store:forget(identity(1));
request(forget_missing) -> erx_bt_store:forget(identity(5));
request(forget_all) -> erx_bt_store:forget(all).

%% A keep's answers with the bond's drawn id taken out, once the link's and the window's
%% are seen to give the same one.
unnamed({ok, <<_:256>> = Id}, {bonded, Id, Identity, Level}) -> {ok, {bonded, Identity, Level}};
unnamed(Kept, Outcome) -> {Kept, Outcome}.

%% The model of "Bonds and the store": whether the change may start, its edit, then its put.
%% `forget all` starts whenever the get it makes for the generation answers, the
%% request's first read after an unconfirmed put.
model(Known, Request, Put, Reread) ->
    Starts = case Known of
                 _ when Request =:= forget_all -> Known =/= unknown_put orelse Reread =/= unavailable;
                 read -> true;
                 unknown_start -> false;
                 unknown_put -> Reread =:= read
             end,
    Edit = case Request of
               keep_kept -> {error, already_bonded};
               forget_missing -> {error, enoent};
               _ -> ok
           end,
    Result = if not Starts -> {error, unavailable};
                Edit =/= ok -> Edit;
                Put =:= ok -> ok;
                true -> {error, unavailable}
             end,
    case Request of
        keep_new -> {Result, outcome(Result, 2)};
        keep_kept -> {Result, outcome(Result, 1)};
        _ -> forget_answer(Result)
    end.

outcome(ok, N) -> {bonded, identity(N), authenticated};
outcome({error, Reason}, _) -> {failed, Reason}.

forget_answer({error, unavailable}) -> {error, eio};
forget_answer(Result) -> Result.

wait_unregistered(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _ -> timer:sleep(1), wait_unregistered(Name)
    end.

%% A forget all that fails after an unread start leaves the store as the start left it:
%% the next pairing is refused rather than read the old bonds under this start's address.
failed_forget_all_after_an_unread_start_changes_nothing_test() ->
    {Store, Script} = start(blob([bond(1)]), [unavailable], [lost]),
    ?assertEqual({error, eio}, erx_bt_store:forget(all)),
    Link = fake_link(),
    keep(Link, 2),
    ?assertEqual({error, unavailable}, kept(Link)),
    ?assertEqual(#{address => ?ADDRESS, bonds => [bond(1)]}, medium(Script)),
    ?assertMatch(#{store := unknown}, erx_bt_store:facts()),
    stop(Store).

%% Kept bonds still resolve after a put the store could not confirm, as on a trial boot.
kept_bonds_resolve_after_an_unconfirmed_put_test() ->
    {Store, _} = start(blob([bond(1)]), [], [lost]),
    Link = fake_link(),
    keep(Link, 2),
    ?assertEqual({error, unavailable}, kept(Link)),
    ?assertMatch(#{store := unknown}, erx_bt_store:facts()),
    ?assertMatch(#{identity := {public, <<0, 0, 0, 0, 0, 1>>}}, erx_bt_store:resolve(identity(1))),
    stop(Store).

%% A put the storage domain completes after the store's deadline, a pairing's holding bond
%% 1, lands after a confirmed forget of bond 1; the bond does not come back at the next
%% start, since the late put's generation is below the forget's.
late_put_never_brings_back_a_forgotten_bond_test_() ->
    {timeout, 30, fun() ->
        Root = string:trim(os:cmd("mktemp -d")),
        Dir = filename:join(Root, "bt"),
        ok = erx_bt_state_file:put(Dir, 1, blob([bond(1)])),
        Storage = slow_storage(Dir, [held]),
        Backend = #{get => fun() -> erx_bt_state_file:get(Dir) end,
                    put => fun(Generation, Blob) ->
                                   Storage ! {put, Generation, Blob, self()},
                                   receive {stored, Answer} -> Answer end
                           end},
        Store = start_backend(Backend, 300),
        Link = fake_link(),
        keep(Link, 2),
        ?assertEqual({error, unavailable}, kept(Link)),
        ?assertEqual(ok, erx_bt_store:forget(identity(1))),
        Storage ! release,
        ?assertEqual(ok, receive {landed, Late} -> Late after 5000 -> not_landed end),
        exit(Storage, kill),
        stop(Store),
        Again = start_backend(Backend, 300),
        ?assertMatch(#{store := read, bonds := []}, erx_bt_store:facts()),
        stop(Again),
        os:cmd("rm -rf " ++ Root)
    end}.

%% The development file under the store with a step of its put failing: a rename onto a
%% directory that holds a name fails, so the pairing fails `unavailable`, its `.new` file
%% goes, the medium keeps the state before it and the store reads before its next change,
%% which succeeds once the rename can.
state_file_step_failing_under_the_store_test() ->
    Root = string:trim(os:cmd("mktemp -d")),
    Dir = filename:join(Root, "bt"),
    ok = erx_bt_state_file:put(Dir, 1, blob([bond(1)])),
    Backend = #{get => fun() -> erx_bt_state_file:get(Dir) end,
                put => fun(Generation, Blob) -> erx_bt_state_file:put(Dir, Generation, Blob) end},
    Store = start_backend(Backend, ?ERX_BT_STORE_TIMEOUT_MS),
    Obstacle = filename:join([Dir, "bonds.2", "held"]),
    ok = filelib:ensure_dir(Obstacle),
    ok = file:write_file(Obstacle, <<>>),
    First = fake_link(),
    keep(First, 2),
    ?assertEqual({error, unavailable}, kept(First)),
    ?assertEqual({failed, unavailable}, outcome(First)),
    ?assertMatch(#{store := unknown}, erx_bt_store:facts()),
    {ok, Left} = file:list_dir(Dir),
    ?assertEqual(["bonds.1", "bonds.2"], lists:sort(Left)),
    ?assertEqual({ok, blob([bond(1)])}, file:read_file(filename:join(Dir, "bonds.1"))),
    ok = file:delete(Obstacle),
    ok = file:del_dir(filename:dirname(Obstacle)),
    Second = fake_link(),
    keep(Second, 2),
    ?assertMatch({ok, <<_:256>>}, kept(Second)),
    {ok, _, Kept} = erx_bt_state_file:get(Dir),
    ?assertMatch({ok, #{bonds := [_, _]}}, erx_bt_state:decode(Kept)),
    stop(Store),
    os:cmd("rm -rf " ++ Root).

%% A put narrows the directory to 0700 and its file to 0600 whatever the directory had
%% and whatever the umask lets a new file have (the seeded fault that drops the file's
%% narrowing needs a umask that leaves a new file more than 0600, as 022 does).
state_file_modes_test() ->
    Root = string:trim(os:cmd("mktemp -d")),
    Dir = filename:join(Root, "bt"),
    ok = file:make_dir(Dir),
    ok = file:change_mode(Dir, 8#755),
    ok = erx_bt_state_file:put(Dir, 1, <<"one">>),
    Mode = fun(Path) -> {ok, #file_info{mode = Bits}} = file:read_file_info(Path), Bits band 8#777 end,
    ?assertEqual(8#700, Mode(Dir)),
    ?assertEqual(8#600, Mode(filename:join(Dir, "bonds.1"))),
    os:cmd("rm -rf " ++ Root).

%% A storage domain that completes each put in a process of its own, whether or not its
%% caller still waits: a `held` one only once the test sends `release`, which it then
%% tells the test has landed, and any other at once.
slow_storage(Dir, Steps) ->
    Test = self(),
    spawn(fun() -> slow_storage(Dir, Test, Steps, []) end).

slow_storage(Dir, Test, Steps, Held) ->
    receive
        {put, Generation, Blob, From} ->
            Put = fun() -> Answer = erx_bt_state_file:put(Dir, Generation, Blob), From ! {stored, Answer}, Answer end,
            case next(Steps, at_once) of
                {held, Rest} -> slow_storage(Dir, Test, Rest, [Put | Held]);
                {at_once, Rest} -> spawn(Put), slow_storage(Dir, Test, Rest, Held)
            end;
        release ->
            [spawn(fun() -> Test ! {landed, Put()} end) || Put <- Held],
            slow_storage(Dir, Test, Steps, [])
    end.
