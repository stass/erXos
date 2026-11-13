%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_srv_tests).
-moduledoc """
erx_pipe_srv's performance of erx_pipe:step/2's actions against a fake
NIF (erx_pipe_fake_nif): the makes come first and a failed one undoes
the step, names become the server's objects, a report is applied to its
holder's end before the holder is told, the last end closes every
object, a forged notice changes nothing, a failed apply of a report
that installs nothing does not loop, a program's ends reach its handler
as hand-offs, an event naming a program from a process that does not
speak for it is refused, a program's ends are gone only on the NIF's
holder-gone message, and a restarted server numbers above its
predecessor.
""".

-include_lib("eunit/include/eunit.hrl").

srv_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun pipe_makes_then_opens/1,
      fun inherit_opens_for_the_child/1,
      fun failed_make_undoes_the_step/1,
      fun report_applied_before_it_is_sent/1,
      fun last_end_closes_every_object/1,
      fun forged_notice_changes_nothing/1,
      fun failed_apply_without_copies_does_not_loop/1,
fun a_programs_pipe_is_handed_off/1,
fun an_event_from_a_non_speaker_is_refused/1,
fun a_programs_ends_go_on_holder_gone_only/1,
fun a_restarted_server_numbers_above_its_predecessor/1]}.

start() ->
    erx_pipe_fake_nif:setup(self()),
    {ok, Pid} = erx_pipe_srv:start_link(#{nif => erx_pipe_fake_nif}),
    unlink(Pid),
    Pid.

stop(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    flush().

pipe_makes_then_opens(_) ->
    {ok, R, W} = erx_pipe_srv:pipe(),
    Calls = calls(),
    Self = self(),
    [{make_lane, 65536}, {make_bell, Self, 1, 1}, {make_bell, Self, 1, 2}, {make_lock, 1},
     {store_wends, Lock, 1}, {open_end, Self, RD}, {open_end, Self, WD}] = Calls,
    [?_assertMatch({obj, lock, _}, Lock),
     ?_assertMatch({pipe, read, {1, 1}, #{lock := Lock, rix := 0}}, RD),
     ?_assertMatch({pipe, write, {1, 2}, #{ring := {obj, ring, _}}}, WD),
     ?_assertEqual({fake_end, Self, RD}, R),
     ?_assertEqual({fake_end, Self, WD}, W),
     ?_assertEqual([], names(RD) ++ names(WD))].

inherit_opens_for_the_child(_) ->
    {ok, _R, W} = erx_pipe_srv:pipe(),
    _ = calls(),
    Child = spawn(fun() -> receive stop -> ok end end),
    Inherited = erx_pipe_srv:inherit(W, Child),
    Calls = calls(),
    Unheld = erx_pipe_srv:inherit({fake_end, self(), none}, Child),
    Child ! stop,
    Self = self(),
    %% The child's doorbell, a new lane, and its end opened for the child; the
    %% parent's read end learns of the new writer.
    [?_assertMatch({ok, {fake_end, Child, {pipe, write, {1, 3}, _}}}, Inherited),
     ?_assertMatch([_], [B || {make_bell, P, 1, 3} = B <- Calls, P =:= Child]),
     ?_assertMatch([_], [O || {open_end, P, _} = O <- Calls, P =:= Child]),
     ?_assertEqual([], [O || {open_end, P, _} = O <- Calls, P =:= Self]),
     ?_assertEqual({error, ebadf}, Unheld)].

failed_make_undoes_the_step(_) ->
    erx_pipe_fake_nif:fail([make_bell]),
    Failed = erx_pipe_srv:pipe(),
    Undo = calls(),
    erx_pipe_fake_nif:fail([]),
    {ok, R, _} = erx_pipe_srv:pipe(),
    Closed = [Obj || {close, Obj} <- Undo],
    [?_assertEqual({error, enomem}, Failed),
     ?_assertEqual(2, length(Closed)),
%% The failed step took no pipe number: its lock was never made.
?_assertEqual([], [Call || {make_lock, _} = Call <- Undo]),
     ?_assertEqual([], [Call || {Op, _} = Call <- Undo, Op =:= open_end]),
     ?_assertEqual([ring, rpage], lists:sort([K || {obj, K, _} <- Closed])),
     %% The old records were kept: the next pipe is pipe 1 again.
     ?_assertMatch({fake_end, _, {pipe, read, {1, 1}, _}}, R)].

report_applied_before_it_is_sent(Srv) ->
    {ok, R, _W} = erx_pipe_srv:pipe(),
    _ = calls(),
    Srv ! {closed, {process, self()}, 1, 2},
    Report = {pipe_writer_gone, 1, 1, 1},
    First = next(),
    Second = next(),
    [?_assertEqual({nif, {apply, R, Report}}, First),
     ?_assertEqual({pipe_report, Report}, Second)].

last_end_closes_every_object(Srv) ->
    {ok, _R, _W} = erx_pipe_srv:pipe(),
    Made = objects(calls()),
    Srv ! {closed, {process, self()}, 1, 2},
    Srv ! {closed, {process, self()}, 1, 1},
    _ = sync(Srv),
    Closed = lists:usort([Obj || {close, Obj} <- calls()]),
    %% The lock page, the lane's ring and reader page, and two doorbells.
    [?_assertEqual(Made, Closed), ?_assertEqual(5, length(Closed))].

forged_notice_changes_nothing(Srv) ->
    {ok, _R, _W} = erx_pipe_srv:pipe(),
    _ = calls(),
    Other = spawn(fun() -> ok end),
    Srv ! {closed, {process, Other}, 1, 2},
    Srv ! {drained, {process, Other}, 1, 1, 1},
    _ = sync(Srv),
    Forged = calls(),
    %% The write end is still the caller's: the read end's close reaches it.
    Srv ! {closed, {process, self()}, 1, 1},
    _ = sync(Srv),
    Reported = [R || {apply, {fake_end, _, {pipe, write, {1, 2}, _}}, R} <- calls()],
    [?_assertEqual([], Forged),
     ?_assertMatch([{pipe_reader_gone, 1, 2, 0}], Reported)].

failed_apply_without_copies_does_not_loop(Srv) ->
    {ok, _R, _W} = erx_pipe_srv:pipe(),
    _ = calls(),
    erx_pipe_fake_nif:fail([apply]),
    Srv ! {closed, {process, self()}, 1, 2},
    _ = sync(Srv),
    Applies = [C || {apply, _, _} = C <- calls()],
    [?_assertEqual(1, length(Applies)), ?_assert(is_process_alive(Srv))].

a_programs_pipe_is_handed_off(_) ->
    erx_pipe_fake_nif:owner(7, self()),
    {ok, {pipe_hand, NR, TR}, {pipe_hand, NW, TW}} = erx_pipe_srv:forward({pipe, {program, 7}, []}),
    Calls = calls(),
    [{hand_make, 7, [{RCopies, {RBell, RLabel}}, {WCopies, {WBell, WLabel}}]}] =
        [C || {hand_make, _, _} = C <- Calls],
    [?_assertNotEqual(NR, NW),
     %% Both doorbells made unbound, for the program's port driver to bind.
     ?_assertEqual([1, 2], [E || {make_bell, {program, 7}, 1, E} <- Calls]),
     ?_assertNotEqual(RBell, WBell),
     %% The read end's own doorbell, unbound, with its label; each object a {hand, I}.
     ?_assertEqual(erx_pipe:label(1, 1), RLabel),
     ?_assertEqual(erx_pipe:label(1, 2), WLabel),
     ?_assertMatch({pipe, read, {1, 1}, #{lock := {hand, 1}, readers := []}}, TR),
     ?_assertMatch({pipe, write, {1, 2}, #{ring := {hand, 1}, rpage := {hand, 2},
                                           readers := [{0, {hand, 3}}]}}, TW),
     ?_assertEqual(4, length(RCopies)),
     ?_assertEqual(3, length(WCopies)),
     ?_assertEqual([], names(TR) ++ names(TW))].

%% docs/design-pipes.md, Verification, program holders: an event naming
%% a program from a process that is not its entry's owner is refused
%% with badarg and changes no record.
an_event_from_a_non_speaker_is_refused(Srv) ->
    erx_pipe_fake_nif:owner(7, self()),
    {ok, _, _} = erx_pipe_srv:forward({pipe, {program, 7}, []}),
    _ = calls(),
    Before = erx_pipe:view(element(3, sync(Srv))),
    Parent = self(),
    Intruder = spawn(fun() -> Parent ! {intruder, erx_pipe_srv:forward({closed, {program, 7}, 1, 2})} end),
    Refused = receive {intruder, R} -> R after 1000 -> timeout end,
    Unowned = erx_pipe_srv:forward({closed, {program, 8}, 1, 2}),
    After = erx_pipe:view(element(3, sync(Srv))),
    Own = erx_pipe_srv:forward({closed, {program, 7}, 1, 2}),
    [?_assert(is_pid(Intruder)),
     ?_assertEqual({error, badarg}, Refused),
     ?_assertEqual({error, badarg}, Unowned),
     ?_assertEqual(Before, After),
     ?_assertEqual(ok, Own)].

%% A program's ends are gone only on the NIF's {erx_pipe_holder_gone, Pid}:
%% no {gone} event from any process names a program.
a_programs_ends_go_on_holder_gone_only(Srv) ->
    erx_pipe_fake_nif:owner(7, self()),
    {ok, _, _} = erx_pipe_srv:forward({pipe, {program, 7}, []}),
    _ = calls(),
    Forged = erx_pipe_srv:forward({gone, {program, 7}}),
    Srv ! {gone, {program, 7}},
    Kept = maps:get(pipes, erx_pipe:view(element(3, sync(Srv)))),
    Srv ! {erx_pipe_holder_gone, 7},
    Gone = maps:get(pipes, erx_pipe:view(element(3, sync(Srv)))),
    [?_assertEqual({error, badarg}, Forged),
     ?_assertMatch(#{1 := _}, Kept),
     ?_assertEqual(#{}, Gone)].

%% docs/design-pipes.md, Verification, program holders: a server
%% restarted over the same NIF numbers its first pipe above every number
%% made before it, which the NIF would otherwise refuse.
a_restarted_server_numbers_above_its_predecessor(Srv) ->
    {ok, _, _} = erx_pipe_srv:pipe(),
    stop(Srv),
    {ok, Next} = erx_pipe_srv:start_link(#{nif => erx_pipe_fake_nif}),
    unlink(Next),
    Second = erx_pipe_srv:pipe(),
    Locks = [P || {make_lock, P} <- calls()],
    stop(Next),
    [?_assertMatch({ok, {fake_end, _, {pipe, read, {2, 1}, _}}, _}, Second),
     ?_assertEqual([2], Locks)].

%% ---------------------------------------------------------------------

%% Every object the fake NIF made, from the calls that returned them.
objects(Calls) ->
    Made = [Obj || Call <- Calls, Obj <- tuple_to_list(Call), is_obj(Obj)]
        ++ [Obj || {open_end, _, {pipe, _, _, Map}} <- Calls,
                   Obj <- lists:flatten([flat(V) || V <- maps:values(Map)]), is_obj(Obj)],
    lists:usort(Made).

flat(T) when is_tuple(T) -> case is_obj(T) of
                                true -> [T];
                                false -> lists:flatten([flat(E) || E <- tuple_to_list(T)])
                            end;
flat(L) when is_list(L) -> lists:flatten([flat(E) || E <- L]);
flat(_) -> [].

is_obj({obj, _, _}) -> true;
is_obj(_) -> false.

%% The names erx_pipe gives objects, left unresolved in a descriptor.
names(Term) ->
    [N || N <- flat_terms(Term), is_name(N)].

flat_terms(T) when is_tuple(T) -> [T | lists:append([flat_terms(E) || E <- tuple_to_list(T)])];
flat_terms(L) when is_list(L) -> lists:append([flat_terms(E) || E <- L]);
flat_terms(M) when is_map(M) -> lists:append([flat_terms(V) || V <- maps:values(M)]);
flat_terms(_) -> [].

is_name({lock, _}) -> true;
is_name({K, _, _}) when K =:= ring; K =:= rpage; K =:= bell -> true;
is_name(_) -> false.

sync(Srv) ->
    sys:get_state(Srv).

calls() ->
    receive {nif, Call} -> [Call | calls()]
    after 100 -> []
    end.

next() ->
    receive Msg -> Msg after 1000 -> timeout end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
