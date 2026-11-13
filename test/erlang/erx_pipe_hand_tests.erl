%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_hand_tests).
-moduledoc """
EUnit cases of the pipe NIF's hand-offs and program holder entries
(docs/design-pipes.md, "Hand-offs" and Verification), over the session's
pipe NIF built for the host with test/fixtures/erx_pipe_harness.c, whose
take/2, give/1 and holder_release/1 stand in for the program driver
(test/host/erx_pipe_hand_test.rb). The test process registers itself as
erx_pipe_srv, so it receives the gone the NIF sends the pipe server.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(RING, ?ERX_PIPE_RING_FIRST).
-define(MEM_RW, (?ERX_HR_READ bor ?ERX_HR_WRITE bor ?ERX_HR_MAP)).
-define(MEM_R, (?ERX_HR_READ bor ?ERX_HR_MAP)).
-define(QUIET, 100).

%% A program's handler: a process that runs what it is sent until told to stop.
owner() ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> owner_loop(Parent) end),
    {Pid, Ref}.

owner_loop(Parent) ->
    receive
        {run, Fun} -> Parent ! {self(), Fun()}, owner_loop(Parent);
        stop -> ok
    end.

run({Pid, _}, Fun) ->
    Pid ! {run, Fun},
    receive {Pid, Result} -> Result after 5000 -> error(owner_timeout) end.

stop({Pid, Ref}) ->
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> error(owner_timeout) end.

%% Runs Fun as the pipe server: the NIF's gone reaches the test process.
as_server(Fun) ->
    true = register(erx_pipe_srv, self()),
    try Fun() after unregister(erx_pipe_srv), flush() end.

flush() ->
    receive {erx_pipe_holder_gone, _} -> flush() after 0 -> ok end.

gone(Program) ->
    receive {erx_pipe_holder_gone, Program} -> ok after 5000 -> error({no_gone, Program}) end.

no_gone(Program) ->
    receive {erx_pipe_holder_gone, Program} -> error({early_gone, Program}) after ?QUIET -> ok end.

%% A program number no other case uses.
program() -> erlang:unique_integer([positive, monotonic]).

%% A write end's hand-off: its lane's ring and reader page, and its own unbound doorbell.
write_end(Program) ->
    {ok, Ring, RPage} = erx_pipe_nif:make_lane(?RING),
    {ok, Bell} = erx_pipe_nif:make_bell({program, Program}, 1, 1),
    {[Ring, RPage, Bell], {[{Ring, ?MEM_RW}, {RPage, ?MEM_R}], {Bell, (1 bsl 32) bor 1}}}.

%% An owner holding Program's entry and one hand-off for it: {Owner, Objects, Number}.
held(Program) ->
    Owner = owner(),
    ok = run(Owner, fun() -> erx_pipe_nif:program_holder(Program) end),
    {Objects, Hand} = write_end(Program),
    {ok, [Number]} = run(Owner, fun() -> erx_pipe_nif:hand_make(Program, [Hand]) end),
    {Owner, Objects, Number}.

caps(Objects) -> [erx_pipe_nif:obj_cap(Object) || Object <- Objects].

close_all(Objects) -> [ok = erx_pipe_nif:close(Object) || Object <- Objects].

owners_take_answers_the_hand_off_once_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        [Ring, RPage, Bell] = caps(Objects),
        ?assertEqual({ok, P, [{Ring, ?MEM_RW}, {RPage, ?MEM_R}], {Bell, (1 bsl 32) bor 1}},
                     erx_pipe_nif:take(N, P, Pid)),
        ok = erx_pipe_nif:give(N),
        ?assertEqual(none, erx_pipe_nif:take(N, P, Pid)),
        stop(Owner),
        ok = erx_pipe_nif:holder_release(P),
        gone(P),
        close_all(Objects)
    end).

take_for_another_owner_answers_none_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        ?assertEqual(none, erx_pipe_nif:take(N, P, self())),
        ?assertMatch({ok, P, [_, _], {_, _}}, erx_pipe_nif:take(N, P, Pid)),
        ok = erx_pipe_nif:give(N),
        stop(Owner),
        ok = erx_pipe_nif:holder_release(P),
        gone(P),
        close_all(Objects)
    end).

take_for_another_program_answers_none_test() ->
    as_server(fun() ->
        P = program(),
        Q = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        ok = run(Owner, fun() -> erx_pipe_nif:program_holder(Q) end),
        ?assertEqual(none, erx_pipe_nif:take(N, Q, Pid)),
        ?assertMatch({ok, P, [_, _], {_, _}}, erx_pipe_nif:take(N, P, Pid)),
        ok = erx_pipe_nif:give(N),
        %% The refused take gave Q's entry no port's hold: the owner's exit ends it.
        stop(Owner),
        gone(Q),
        no_gone(P),
        ok = erx_pipe_nif:holder_release(P),
        gone(P),
        close_all(Objects)
    end).

take_after_the_ports_release_is_refused_test() ->
    as_server(fun() ->
        P = program(),
        {Pid, _} = Owner = owner(),
        ok = run(Owner, fun() -> erx_pipe_nif:program_holder(P) end),
        {First, Hand1} = write_end(P),
        {Second, Hand2} = write_end(P),
        {ok, [N1, N2]} = run(Owner, fun() -> erx_pipe_nif:hand_make(P, [Hand1, Hand2]) end),
        {ok, P, _, _} = erx_pipe_nif:take(N1, P, Pid),
        ok = erx_pipe_nif:give(N1),
        ok = erx_pipe_nif:holder_release(P),
        ?assertEqual(none, erx_pipe_nif:take(N2, P, Pid)),
        %% No port holds the entry again, so the owner's exit is the program's gone.
        stop(Owner),
        gone(P),
        close_all(First ++ Second)
    end).

release_before_any_take_is_final_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        ok = erx_pipe_nif:holder_release(P),
        ?assertEqual(none, erx_pipe_nif:take(N, P, Pid)),
        stop(Owner),
        gone(P),
        close_all(Objects)
    end).

holder_drop_lets_its_held_hand_offs_go_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        Caps = caps(Objects),
        ok = run(Owner, fun() -> erx_pipe_nif:holder_drop(P) end),
        gone(P),
        ?assertEqual(none, erx_pipe_nif:take(N, P, Pid)),
        ?assertEqual([false, false, false], [erx_pipe_nif:closed(C) || C <- Caps]),
        %% The hand-off kept nothing, so the server's close is the last.
        close_all(Objects),
        ?assertEqual([true, true, true], [erx_pipe_nif:closed(C) || C <- Caps]),
        stop(Owner),
        no_gone(P)
    end).

hand_make_refuses_more_than_its_limits_test() ->
    P = program(),
    ok = erx_pipe_nif:program_holder(P),
    {ok, Ring, RPage} = erx_pipe_nif:make_lane(?RING),
    Copies = lists:duplicate(?ERX_PIPE_HAND_COPIES_MAX, {Ring, ?MEM_R}),
    ?assertMatch({ok, [_]}, erx_pipe_nif:hand_make(P, [{Copies, none}])),
    ?assertError(badarg, erx_pipe_nif:hand_make(P, [{[{Ring, ?MEM_R} | Copies], none}])),
    Empty = lists:duplicate(?ERX_PROG_FDS_MAX, {[], none}),
    {ok, Numbers} = erx_pipe_nif:hand_make(P, Empty),
    ?assertEqual(?ERX_PROG_FDS_MAX, length(Numbers)),
    ?assertError(badarg, erx_pipe_nif:hand_make(P, [{[], none} | Empty])),
    ok = erx_pipe_nif:holder_drop(P),
    close_all([Ring, RPage]),
    ?assertEqual([true, true], [erx_pipe_nif:closed(C) || C <- caps([Ring, RPage])]).

hand_drop_lets_a_held_hand_off_go_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        ok = run(Owner, fun() -> erx_pipe_nif:hand_drop(N) end),
        ?assertEqual(none, erx_pipe_nif:take(N, P, Pid)),
        ?assertEqual([false, false, false], [erx_pipe_nif:closed(C) || C <- caps(Objects)]),
        close_all(Objects),
        ?assertEqual([true, true, true], [erx_pipe_nif:closed(C) || C <- caps(Objects)]),
        stop(Owner),
        gone(P)
    end).

hand_drop_of_another_owner_does_nothing_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        ?assertEqual(ok, erx_pipe_nif:hand_drop(N)),
        ?assertMatch({ok, P, _, _}, erx_pipe_nif:take(N, P, Pid)),
        ok = erx_pipe_nif:give(N),
        stop(Owner),
        ok = erx_pipe_nif:holder_release(P),
        gone(P),
        close_all(Objects)
    end).

hand_drop_does_nothing_to_a_taken_hand_off_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        {ok, P, _, _} = erx_pipe_nif:take(N, P, Pid),
        close_all(Objects),
        ok = run(Owner, fun() -> erx_pipe_nif:hand_drop(N) end),
        Caps = caps(Objects),
        ?assertEqual([false, false, false], [erx_pipe_nif:closed(C) || C <- Caps]),
        ok = erx_pipe_nif:give(N),
        ?assertEqual([true, true, true], [erx_pipe_nif:closed(C) || C <- Caps]),
        stop(Owner),
        ok = erx_pipe_nif:holder_release(P),
        gone(P)
    end).

owners_exit_lets_its_hand_offs_go_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        Caps = caps(Objects),
        stop(Owner),
        gone(P),
        ?assertEqual(none, erx_pipe_nif:take(N, P, Pid)),
        ?assertEqual([false, false, false], [erx_pipe_nif:closed(C) || C <- Caps]),
        close_all(Objects),
        ?assertEqual([true, true, true], [erx_pipe_nif:closed(C) || C <- Caps])
    end).

gone_after_the_owner_then_the_port_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        {ok, P, _, _} = erx_pipe_nif:take(N, P, Pid),
        ok = erx_pipe_nif:give(N),
        stop(Owner),
        no_gone(P),
        ok = erx_pipe_nif:holder_release(P),
        gone(P),
        ok = erx_pipe_nif:holder_release(P),
        no_gone(P),
        close_all(Objects)
    end).

gone_after_the_port_then_the_owner_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, N} = held(P),
        {ok, P, _, _} = erx_pipe_nif:take(N, P, Pid),
        ok = erx_pipe_nif:give(N),
        ok = erx_pipe_nif:holder_release(P),
        no_gone(P),
        ok = run(Owner, fun() -> erx_pipe_nif:holder_drop(P) end),
        gone(P),
        stop(Owner),
        no_gone(P),
        close_all(Objects)
    end).

second_program_holder_is_refused_test() ->
    as_server(fun() ->
        P = program(),
        {{Pid, _} = Owner, Objects, _} = held(P),
        Other = owner(),
        ?assertEqual({error, eexist}, run(Other, fun() -> erx_pipe_nif:program_holder(P) end)),
        ?assertEqual({error, eexist}, run(Owner, fun() -> erx_pipe_nif:program_holder(P) end)),
        ?assertEqual({ok, Pid}, erx_pipe_nif:holder_owner(P)),
        ok = run(Other, fun() -> erx_pipe_nif:holder_drop(P) end),
        ?assertEqual({ok, Pid}, erx_pipe_nif:holder_owner(P)),
        stop(Other),
        stop(Owner),
        gone(P),
        ?assertEqual(none, erx_pipe_nif:holder_owner(P)),
        close_all(Objects)
    end).

hand_make_without_a_held_entry_makes_none_test() ->
    P = program(),
    {Objects, Hand} = write_end(P),
    ?assertEqual(none, erx_pipe_nif:hand_make(P, [Hand])),
    close_all(Objects),
    ?assertEqual([true, true, true], [erx_pipe_nif:closed(C) || C <- caps(Objects)]).

hand_make_refuses_rights_a_copy_cannot_carry_test() ->
    P = program(),
    ok = erx_pipe_nif:program_holder(P),
    {ok, Ring, RPage} = erx_pipe_nif:make_lane(?RING),
    {ok, Bell} = erx_pipe_nif:make_bell({program, P}, 1, 1),
    {ok, SessionBell} = erx_pipe_nif:make_bell(self(), 1, 1),
    Bad = [{[{Ring, ?ERX_HR_READ bor ?ERX_HR_WRITE}], none},
           {[{Ring, ?MEM_RW bor ?ERX_HR_DUP}], none},
           {[{RPage, ?MEM_R bor ?ERX_HR_GIVE}], none},
           {[{Bell, ?ERX_HR_TRIGGER bor ?ERX_HR_DESTROY}], none},
           {[{Ring, ?ERX_HR_TRIGGER}], none},
           {[], {Ring, (1 bsl 32) bor 1}},
           {[], {Bell, 1}},
           {[], {SessionBell, (1 bsl 32) bor 1}}],
    [?assertError(badarg, erx_pipe_nif:hand_make(P, [B])) || B <- Bad],
    ?assertError(badarg, erx_pipe_nif:hand_make(P, [{[{Ring, ?MEM_RW}], none}, hd(Bad)])),
    ok = erx_pipe_nif:holder_drop(P),
    close_all([Ring, RPage, Bell, SessionBell]),
    ?assertEqual([true, true, true, true],
                 [erx_pipe_nif:closed(C) || C <- caps([Ring, RPage, Bell, SessionBell])]).

make_lock_refuses_a_number_already_made_test() ->
    Made = erx_pipe_nif:pipes_made(),
    {ok, Lock} = erx_pipe_nif:make_lock(Made + 2),
    ?assertEqual(Made + 2, erx_pipe_nif:pipes_made()),
    ?assertEqual({error, einval}, erx_pipe_nif:make_lock(Made + 1)),
    ?assertEqual({error, einval}, erx_pipe_nif:make_lock(Made + 2)),
    ?assertError(badarg, erx_pipe_nif:make_lock(0)),
    ok = erx_pipe_nif:close(Lock).
