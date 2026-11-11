%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random sequences of messages through erx_fs_grant, the pure core of one erx_fs grant,
%% over erx_fs_test_tree: valid requests on a few fids and names of the tree, requests with
%% one field replaced, arbitrary terms, frames whose alias or owner belongs to another
%% domain, frames in another domain's envelope or bare, flushes, owners going down and
%% file answers with the wrong tag. A sequence's grant serves the server's own domain or
%% another, ?CLIENT, whose frames arrive in its envelope, {erx_origin, ?CLIENT, Frame},
%% with names of its node, as edit 16 delivers them; erx_dist's stand-in reads a name's
%% domain as the BIF does. A shell here performs the core's effects as erx_fs does,
%% holding back a file process's jobs for a while so requests stay in flight and flushes
%% find them.
%%
%% Whatever arrives, the core never raises, and:
%% * a reply goes only to an alias of the client's domain whose frame, in the client's
%%   envelope or bare for the server's own domain, awaits one, and
%%   decode_reply/2 accepts it for that frame's request (an error reply, for a frame the
%%   grammar refused); the core runs the same check before it replies, so what this adds
%%   is the alias, the count and the order: a flush answered ok comes after what it flushed;
%% * a file process gets only jobs with its own tag, none after its last clunk, and the
%%   grant's open files each have a running process;
%% * the fids stay within the pool, the owners and the open files within the fids, the
%%   requests in flight within 64, and the grant's owners are exactly the owners the shell
%%   holds a monitor for;
%% * at the end of a sequence, with every job run and every owner down, every frame that
%%   awaits a reply has had exactly one, and the grant holds nothing.
%% The seed comes from make check-fuzz.

-module(erx_fs_grant_fuzz).
-export([run/1]).

-define(G, erx_9p_grammar).
-define(CORE, erx_fs_grant).
-define(TREE, erx_fs_test_tree).
-define(SEQUENCES, 30000).
-define(STEPS, 60).
-define(IN_FLIGHT_MAX, 64).
-define(ALL_JOBS, 1 bsl 30).
-define(FOREIGN, <<"other@far">>).
%% Another domain a grant may serve, and a third domain, as their names carry them.
-define(CLIENT, 5).
-define(THIRD, 9).
-define(DOMAIN_NODE, <<"d@erxos11">>).

%% The shell's view of one sequence: the core, the tree's handle, the domain the grant
%% serves, the frames each of that domain's aliases awaits a reply for (each numbered in the order sent) and the replies it has had,
%% the monitor it holds for each owner, and each live file process with its tag and the
%% jobs it has not run yet, oldest first.
-record(shell, {core, fs, client, owners, awaited = #{}, replies = #{}, sent = 0, monitors = #{},
                files = #{}, aliases = [], pool, tally = #{}}).

run([Seed]) ->
    rand:seed(exsss, {16#f5, 16#9a, list_to_integer(Seed)}),
    Tally = lists:foldl(fun(_, T) -> sequence(T) end, #{}, lists:seq(1, ?SEQUENCES)),
    io:format("fuzz: ~p sequences ok~n", [?SEQUENCES]),
    [io:format("~p ~p: ~p~n", [Op, Outcome, N]) || {Op, Outcome} := N <- maps:iterator(Tally, ordered)],
    ok.

sequence(Tally) ->
    {ok, #{tree := Tree} = Fs} = ?TREE:init([]),
    Client = pick([own, ?CLIENT]),
    Owners = owners(Client),
    Pool = pick([1, 2, 3, 8, 4096]),
    Core = ?CORE:new(#{module => ?TREE, fs => Fs, rights => pick([ro, rw, rx]),
                       client => Client, pool => Pool}),
    Shell = #shell{core = Core, fs = Fs, client = Client, owners = Owners, pool = Pool, tally = Tally},
    %% Most sequences open as a client does, so later requests find a session and a fid.
    Prologue = case rand:uniform(4) of
                   1 -> [];
                   _ -> [{version, 8192, <<"9P2000.L">>}, {attach, 0, 16#ffffffff, <<"u">>, <<"test">>, 0}]
               end,
    Opened = lists:foldl(fun(Request, S) -> checked(frame(delivered(request_frame(Request, S), S), S)) end,
                         Shell, Prologue),
    Steps = lists:foldl(fun(_, S) -> checked(step(S)) end, Opened,
                        lists:seq(1, rand:uniform(?STEPS))),
    Counted = finished(Steps),
    [begin unlink(Pid), exit(Pid, kill) end || Pid <- [Tree | Owners], Pid =/= self(), node(Pid) =:= node()],
    Counted.

idle() ->
    receive stop -> ok end.

%% The owners a sequence's frames name: this test and two idle processes for the
%% server's own domain, and three pids of the client's node for another domain.
owners(own) -> [self() | [spawn_link(fun idle/0) || _ <- [1, 2]]];
owners(Client) -> [domain_pid(Client, N) || N <- [1, 2, 3]].

step(Shell) ->
    case rand:uniform(20) of
        N when N =< 13 -> frame(delivered(request_frame(request(Shell), Shell), Shell), Shell);
        14 -> frame(delivered(request_frame(mutated(request(Shell)), Shell), Shell), Shell);
        15 -> frame(odd_frame(Shell), Shell);
        16 -> owner_down(Shell);
        17 -> stray_answer(Shell);
        _ -> run_jobs(rand:uniform(4), Shell)
    end.

%% One message to the core, with what the shell expects back for it.
frame(Frame, #shell{core = Core} = Shell) ->
    {Effects, Core1} = ?CORE:handle_frame(Frame, Core),
    effects(Effects, expect(Frame, Shell#shell{core = Core1})).

expect(Message, #shell{awaited = Awaited, client = Client} = Shell) ->
    Ours = fun(Alias) -> of_client(Alias, Client) end,
    Expected = case ?G:decode_request_frame(frame_of(Message, Client)) of
                   {ok, Alias, _, Request} -> Ours(Alias) andalso {Alias, {request, Request}};
                   {error, Alias, _} -> Ours(Alias) andalso {Alias, refused};
                   error -> false
               end,
    case Expected of
        {A, What} ->
            Sent = Shell#shell.sent,
            Shell#shell{awaited = Awaited#{A => maps:get(A, Awaited, []) ++ [{Sent, What}]},
                        sent = Sent + 1, aliases = [A | Shell#shell.aliases]};
        false ->
            Shell
    end.

%% The core's effects, performed in order as erx_fs performs them.
effects([], Shell) ->
    Shell;
effects([{reply, Alias, Reply} | Rest], Shell) ->
    effects(Rest, replied(Alias, Reply, Shell));
effects([{monitor, Owner} | Rest], #shell{core = Core, monitors = Monitors} = Shell) ->
    is_map_key(Owner, Monitors) andalso error({monitored_twice, Owner}),
    Ref = make_ref(),
    effects(Rest, Shell#shell{core = ?CORE:monitored(Owner, Ref, Core),
                              monitors = Monitors#{Owner => Ref}});
effects([{demonitor, Ref} | Rest], #shell{monitors = Monitors} = Shell) ->
    case [Owner || Owner := R <- Monitors, R =:= Ref] of
        [Owner] -> effects(Rest, Shell#shell{monitors = maps:remove(Owner, Monitors)});
        [] -> error({demonitor_of_no_monitor, Ref})
    end;
effects([{start_file, Node, ?TREE, Fs} | Rest], #shell{core = Core, fs = Fs, files = Files} = Shell) ->
    {Process, Tag} = {spawn_link(fun idle/0), make_ref()},
    effects(Rest, Shell#shell{core = ?CORE:file_started(Node, Process, Tag, Core),
                              files = Files#{Process => {Tag, queue:new()}}});
%% A file process takes only jobs with its own tag, and none once it has ended.
effects([{run, Process, Tag, Job} | Rest], #shell{files = Files} = Shell) ->
    case Files of
        #{Process := {Tag, Jobs}} ->
            effects(Rest, Shell#shell{files = Files#{Process := {Tag, queue:in(Job, Jobs)}}});
        #{} ->
            error({check_failed, job_for_no_file_process, Process, Tag, Job})
    end;
effects([Effect | _], _) ->
    error({unexpected_effect, Effect}).

%% A client may send several frames with one alias, and their replies carry nothing else
%% that tells them apart, so the replies an alias has had must match its frames one to
%% one in some order, each valid for the frame it matches.
%% A flush answered ok comes after the replies of every frame it may have flushed: those
%% sent with its old tag before it (docs/design-files.md, flush).
replied(Alias, Reply, #shell{awaited = Awaited, replies = Replies, tally = Tally} = Shell) ->
    Waiting = [What || {_, What} <- maps:get(Alias, Awaited, [])],
    Had = [Reply | maps:get(Alias, Replies, [])],
    matched(Had, Waiting) orelse error({check_failed, unexpected_reply, Alias, Reply, Waiting}),
    Flushes = [{Sent, Old} || {Sent, {request, {flush, Old}}} <- maps:get(Alias, Awaited, []), Reply =:= ok],
    Flushes =:= [] orelse lists:any(fun({Sent, Old}) -> flushed_after(Old, Sent, Shell) end, Flushes)
        orelse error({check_failed, flush_answered_first, Alias, Flushes}),
    [What | _] = [W || W <- Waiting, valid_reply(W, Reply)],
    Key = {case What of {request, R} -> element(1, R); refused -> refused end, outcome(Reply)},
    Shell#shell{replies = Replies#{Alias => Had}, tally = Tally#{Key => maps:get(Key, Tally, 0) + 1}}.

flushed_after(Old, Sent, #shell{awaited = Awaited, replies = Replies}) ->
    Before = [S || {S, _} <- maps:get(Old, Awaited, []), S < Sent],
    length(maps:get(Old, Replies, [])) >= length(Before).

%% Whether each reply has a frame of its own among Waiting that it is valid for.
matched([], _) ->
    true;
matched([Reply | Rest], Waiting) ->
    lists:any(fun(What) -> valid_reply(What, Reply) andalso matched(Rest, Waiting -- [What]) end,
              Waiting).

valid_reply({request, Request}, Reply) ->
    ?G:decode_reply(Request, Reply) =:= {ok, Reply};
valid_reply(refused, {error, _} = Reply) ->
    ?G:decode_reply({clunk, 0}, Reply) =:= {ok, Reply};
valid_reply(refused, _) ->
    false.

%% Each file process runs its own jobs in the order they were sent, and the processes run
%% concurrently: each step runs the next job of a file process drawn at random. A process
%% ends at its last clunk, which must be its last job.
run_jobs(0, Shell) ->
    Shell;
run_jobs(N, #shell{files = Files, fs = Fs} = Shell) ->
    case [Process || Process := {_, Jobs} <- Files, not queue:is_empty(Jobs)] of
        [] ->
            Shell;
        Busy ->
            Process = pick(Busy),
            {Tag, Jobs} = maps:get(Process, Files),
            {{value, Job}, Rest} = queue:out(Jobs),
            Shell1 = Shell#shell{files = Files#{Process := {Tag, Rest}}},
            case ?CORE:run_job(Job, ?TREE, Fs) of
                {answer, Alias, Reply} ->
                    {Effects, Core} = ?CORE:file_answer(Tag, Alias, Reply, Shell1#shell.core),
                    run_jobs(N - 1, effects(Effects, Shell1#shell{core = Core}));
                continue ->
                    run_jobs(N - 1, Shell1);
                stop ->
                    queue:is_empty(Rest) orelse error({check_failed, job_after_last_clunk, queue:to_list(Rest)}),
                    unlink(Process),
                    exit(Process, kill),
                    run_jobs(N - 1, Shell1#shell{files = maps:remove(Process, Files)})
            end
    end.

%% An owner's DOWN, with its monitor's reference or, now and then, another one, which
%% changes nothing. Its fids end, and the last one's demonitor removes the shell's monitor.
owner_down(#shell{core = Core, owners = Owners, monitors = Monitors} = Shell) ->
    Owner = pick(Owners),
    Ref = case rand:uniform(4) of
              1 -> make_ref();
              _ -> maps:get(Owner, Monitors, make_ref())
          end,
    {Effects, Core1} = ?CORE:owner_down(Ref, Owner, Core),
    #shell{monitors = After} = Shell1 = effects(Effects, Shell#shell{core = Core1}),
    Gone = maps:get(Owner, Monitors, none) =/= Ref orelse not is_map_key(Owner, After),
    Gone orelse error({check_failed, monitor_kept_after_down, Owner}),
    Shell1.

%% A file answer the core did not ask for: a tag no file process has, for an alias in
%% flight or not. It answers nothing.
stray_answer(#shell{core = Core} = Shell) ->
    Alias = pick([make_ref() | Shell#shell.aliases]),
    {Effects, Core1} = ?CORE:file_answer(make_ref(), Alias, random_field(), Core),
    effects(Effects, Shell#shell{core = Core1}).

checked(#shell{core = Core, monitors = Monitors, pool = Pool} = Shell) ->
    #{fids := Fids, owners := Owners, files := Files, in_flight := InFlight} = ?CORE:info(Core),
    Bounds = [{fids_within_pool, Fids =< Pool}, {owners_within_fids, Owners =< Fids},
              {files_within_fids, Files =< Fids}, {in_flight_within_bound, InFlight =< ?IN_FLIGHT_MAX},
              {owners_are_monitored, Owners =:= map_size(Monitors)},
              {files_are_running, Files =< map_size(Shell#shell.files)}],
    case [Name || {Name, false} <- Bounds] of
        [] -> Shell;
        Broken -> error({check_failed, Broken})
    end.

finished(Shell) ->
    Ran = run_jobs(?ALL_JOBS, Shell),
    Down = lists:foldl(fun(Owner, #shell{core = Core, monitors = Monitors} = S) ->
                               case Monitors of
                                   #{Owner := Ref} ->
                                       {Effects, Core1} = ?CORE:owner_down(Ref, Owner, Core),
                                       effects(Effects, S#shell{core = Core1});
                                   #{} -> S
                               end
                       end, Ran, Ran#shell.owners),
    #shell{core = Core, awaited = Awaited, replies = Replies} = Done = run_jobs(?ALL_JOBS, Down),
    Info = ?CORE:info(Core),
    Empty = maps:with([fids, owners, files, in_flight], Info) =:=
        #{fids => 0, owners => 0, files => 0, in_flight => 0},
    Empty orelse error({check_failed, held_at_the_end, Info}),
    map_size(Done#shell.files) =:= 0 orelse error({check_failed, file_process_left, Done#shell.files}),
    Unanswered = [{Alias, Waiting} || Alias := Waiting <- Awaited,
                                      length(Waiting) =/= length(maps:get(Alias, Replies, []))],
    Unanswered =:= [] orelse error({check_failed, unanswered, Unanswered}),
    Done#shell.tally.

outcome({error, Posix}) -> Posix;
outcome(_) -> ok.

%% A request of the grammar's table on the fids and names a sequence keeps reusing.
request(Shell) ->
    Fid = fid(),
    %% Walks, opens, reads and writes are drawn more often, so sequences reach open files.
    case pick([1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 15, 15, 21, 21 |
               lists:seq(10, 26)]) of
        1 -> {version, pick([4096, 8192, 65560, 4095, 65561]), pick([<<"9P2000.L">>, <<"9P2000">>])};
        2 -> {attach, Fid, 16#ffffffff, <<"u">>, pick([<<"test">>, <<"test">>, <<"tmp">>, <<>>]), 0};
        3 -> {walk, Fid, fid(), [name() || _ <- lists:seq(1, rand:uniform(4) - 1)]};
        4 -> {walk, Fid, fid(), pick([[], [<<"a">>], [<<"f">>], [<<"l">>], [<<"a">>, <<"b">>], [<<"a">>, <<"f">>],
                                     [<<"a">>, <<"..">>, <<"f">>], [<<"n">>], [<<"m">>]])};
        5 -> {lopen, Fid, flags()};
        6 -> {lcreate, Fid, name(), flags(), 8#644, 0};
        7 -> {read, Fid, offset(), count()};
        8 -> {write, Fid, offset(), pick([<<>>, <<"abc">>, binary:copy(<<"x">>, 5000)])};
        9 -> {readdir, Fid, offset(), count()};
        10 -> {getattr, Fid, pick([0, 16#3fff, 16#ffffffffffffffff])};
        11 -> {setattr, Fid, #{valid => pick([0, 1, 8, 9, 16#1ff]), mode => pick([8#644, 8#40755]),
                               uid => 0, gid => 0, size => pick([0, 3, 4097, 16#7fffffffffffffff]), atime_sec => 0,
                               atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0}};
        12 -> {mkdir, Fid, name(), 8#755, 0};
        13 -> {symlink, Fid, name(), pick([<<"a">>, <<"/">>, <<"..">>]), 0};
        14 -> {link, Fid, fid(), name()};
        15 -> {readlink, Fid};
        16 -> {unlinkat, Fid, name(), pick([0, 16#200])};
        17 -> {renameat, Fid, name(), fid(), name()};
        18 -> {statfs, Fid};
        19 -> {fsync, Fid, pick([0, 1])};
        20 -> {flush, pick([make_ref() | Shell#shell.aliases])};
        21 -> {clunk, Fid};
        22 -> {remove, Fid};
        23 -> {mknod, Fid, name(), 8#644, 0, 0, 0};
        24 -> {xattrwalk, Fid, fid(), pick([<<>>, <<"user.a">>])};
        25 -> {xattrcreate, Fid, <<"user.a">>, 0, 0};
        26 -> pick([{lock, Fid, 1, 0, 0, 0, 1, <<"h">>}, {getlock, Fid, 0, 0, 0, 1, <<"h">>}])
    end.

%% A frame with its own owner and alias, of the client's domain, around Request, now and
%% then the same alias as a frame before it, which the core answers once more.
request_frame(Request, Shell) ->
    Alias = case rand:uniform(8) of
                1 when Shell#shell.aliases =/= [] -> pick(Shell#shell.aliases);
                _ -> alias(Shell#shell.client)
            end,
    {erx_9p, Alias, pick(Shell#shell.owners), Request}.

mutated({flush, _} = Request) ->
    setelement(2, Request, random_field());
mutated(Request) ->
    setelement(1 + rand:uniform(tuple_size(Request) - 1), Request, random_field()).

%% A message the client's domain never sends: a frame whose alias or owner is of another
%% domain, an alias that is no reference, an owner that is no pid, the wrong arity, any
%% term, a client's frame in another domain's envelope, or bare from another domain.
odd_frame(#shell{client = Client} = Shell) ->
    {erx_9p, Alias, Owner, Request} = Frame = request_frame(request(Shell), Shell),
    case rand:uniform(8) of
        1 -> delivered({erx_9p, other_alias(Client), Owner, Request}, Shell);
        2 -> delivered({erx_9p, Alias, other_owner(Client), Request}, Shell);
        3 -> delivered({erx_9p, pick([self(), 1, <<>>]), Owner, Request}, Shell);
        4 -> delivered({erx_9p, Alias, pick([Alias, node(), 0]), Request}, Shell);
        5 -> delivered({erx_9p, Alias, Owner}, Shell);
        6 -> pick([random_field(), {erx_9p}, {Alias, Request}, Request]);
        7 -> {erx_origin, pick([0, 1, 7, ?THIRD]), Frame};
        8 when Client =:= own -> {erx_origin, ?CLIENT, Frame};
        8 -> Frame
    end.

%% Message as the grant receives Frame from the client's domain: bare from the server's
%% own, in the envelope of edit 16 from another.
delivered(Frame, #shell{client = own}) -> Frame;
delivered(Frame, #shell{client = Client}) -> {erx_origin, Client, Frame}.

%% The frame inside a message the client's domain sent, or none for any other message.
frame_of({erx_origin, Client, Frame}, Client) when is_integer(Client) -> Frame;
frame_of({erx_origin, _, _}, _) -> none;
frame_of(Frame, own) -> Frame;
frame_of(_, _) -> none.

%% Whether a frame's alias is of the client's domain: of this node for the server's own,
%% of the client's id, as erx_dist reads it, for another.
of_client(Alias, own) -> node(Alias) =:= node();
of_client(Alias, Client) -> erx_dist:owner(Alias) =:= Client.

%% A fresh alias of the client's domain.
alias(own) -> make_ref();
alias(Client) -> domain_ref(Client).

%% An alias and an owner that are not the client domain's.
other_alias(own) -> pick([foreign_ref(), domain_ref(?THIRD)]);
other_alias(_) -> pick([foreign_ref(), domain_ref(?THIRD), make_ref()]).

other_owner(own) -> pick([foreign_pid(), domain_pid(?THIRD, 1)]);
other_owner(_) -> pick([foreign_pid(), domain_pid(?THIRD, 1), self()]).


fid() ->
    pick([0, 0, 0, 1, 1, 1, 2, 2, 3, 16#fffffffe, 16#ffffffff]).

name() ->
    pick([<<"a">>, <<"b">>, <<"f">>, <<"l">>, <<"..">>, <<"n">>, <<"m">>, <<".">>, <<>>, <<"a/b">>]).

flags() ->
    pick([0, 1, 2, 8#100, 8#101, 8#302, 8#1001, 8#2001, 8#200000, 3]).

offset() ->
    pick([0, 0, 1, 3, 4096, 16#7fffffffffffffff, 16#ffffffffffffffff]).

count() ->
    pick([0, 1, 24, 64, 300, 4096, 65536, 16#ffffffff]).

random_field() ->
    case rand:uniform(7) of
        1 -> pick([0, 1, -1, 16#ffffffff, 16#100000000, 16#ffffffffffffffff, 1 bsl 64]);
        2 -> name();
        3 -> binary:copy(<<"n">>, pick([255, 256, 65537]));
        4 -> [name() || _ <- lists:seq(1, pick([0, 1, 16, 17]))];
        5 -> make_ref();
        6 -> pick([ok, error, enoent, 1.5, [], {}, #{}, self()]);
        7 -> {pick([read, walk, ok]), random_term()}
    end.

random_term() ->
    pick([{0, 0, 0}, [1], #{valid => 1}, <<0>>, foreign_pid()]).

%% A pid and a reference of another node, built from their external formats
%% (NEW_PID_EXT and NEWER_REFERENCE_EXT) with a node name of SMALL_ATOM_UTF8_EXT.
foreign_pid() ->
    binary_to_term(<<131, 88, 119, (byte_size(?FOREIGN)), ?FOREIGN/binary, 1:32, 0:32, 1:32>>).

foreign_ref() ->
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(?FOREIGN)), ?FOREIGN/binary, 1:32,
                     (rand:uniform(1000)):32, 0:32, 0:32>>).

%% A pid and a reference of domain D's node, whose creation is the domain id; each
%% reference is new.
domain_pid(D, N) ->
    binary_to_term(<<131, 88, 119, (byte_size(?DOMAIN_NODE)), ?DOMAIN_NODE/binary, N:32, 0:32, D:32>>).

domain_ref(D) ->
    Id = erlang:unique_integer([positive]) band 16#ffffffff,
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(?DOMAIN_NODE)), ?DOMAIN_NODE/binary, D:32,
                     1:32, Id:32, 0:32>>).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
