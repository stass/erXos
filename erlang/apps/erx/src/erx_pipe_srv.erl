%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_srv).
-moduledoc """
The session's pipe server (docs/design-pipes.md, "The pipe server"): the
process that performs erx_pipe:step/2's actions with the pipe NIF.

erx_pipe:step/2 decides everything; this process only carries out each
action, in the order given, and turns what happens outside it back into
events:

* the makes create the objects with the session's budget and keep the
  server's own capability to each, as a NIF resource this process owns,
  under the name the step gave it; a make that fails closes what the
  step made, keeps the old records and answers `enomem`;
* `store_wends`, `free_lock` and `close` are one NIF call each;
* a report to a session process is applied to the process's end, which
  this process made and keeps, and then sent to the process as
  `{pipe_report, Report}`, so the end has what the report names before
  its holder can act on it; a holder's reports are applied in the order
  the steps give them, which the doorbell's close when a write end is
  forgotten relies on (erx_pipe, forget_writer); an apply that fails
  comes back as the event `install_failed`;
* a reply to a session process opens its ends, NIF resources the
  process owns and the NIF monitors.

The ends tell the server of themselves: the NIF sends `{closed, Holder,
Pipe, End}` when the owning process closes an end or exits, and
`{drained, Holder, Pipe, End, Writer}` when a read end has drained a
gone writer's lane. When this process ends, the NIF counts every end it
made lost and tells each end's owner `{pipe_server_lost, End}`, so a
waiting reader fails with `{error, eio}` and never sees a false end of
stream; the supervisor starts a server for later pipes.

Programs reach the server through their handlers (erx_prog_handler),
which forward each request and notice of their program with forward/1,
the program `{program, Pid}` as the holder (docs/design-pipes.md,
"Hand-offs"). An event naming a program is run only when its sender
speaks for the program, the owner of the program's holder entry in the
NIF (erx_pipe_nif:holder_owner/1): the event's holder, or for an
`inherit` the child it names, since the child's handler asks for the
child's ends; any other sender gets `{error, badarg}` and no record
changes. What a program gains is a hand-off the NIF holds for its
handler (erx_pipe_nif:hand_make/2): a reply names each end as
`{pipe_hand, Number, Term}`, and a report that lists copies reaches the
handler as `{pipe_report, Pid, {pipe_hand, Number, Term}}`, one without
as `{pipe_report, Pid, Report}`, where `Term` is the descriptor or the
report with each object written `{hand, I}`, its copy's place in
erx_pipe:copies/1's list. A program's ends are gone only on the NIF's
`{erx_pipe_holder_gone, Pid}`, sent once no image of the program runs;
the server monitors no handler. Pipe numbers start one past
erx_pipe_nif:pipes_made/0, so a restarted server repeats none.

read/3 and write/3 are the blocking calls a session process makes on
its ends: the NIF never waits, and where it would it returns
`would_block` and the process waits for its end's doorbell message
`{erx_pipe_ready, Pipe, End}`, a report or the server's loss.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1, pipe/0, inherit/2, forward/1, read/3, write/3, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(srv, {nif :: module(),
              pipes :: erx_pipe:state(),
              %% The server's own capability to each object, by its name.
              objects = #{} :: #{erx_pipe:object() => term()},
              %% The ends of session processes, with their owners, by pipe and end number.
              ends = #{} :: #{{pos_integer(), pos_integer()} => {pid(), term()}}}).

-doc "Starts the session's pipe server, registered as erx_pipe_srv.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc """
Starts the pipe server with options: `nif`, the module of the pipe NIF
(erx_pipe_nif unless given, a fake in the tests), and `quota`, the
session's `pipes` quota of lanes, which erx_pipe:new/1 defaults and bounds.
""".
-spec start_link(#{nif => module(), quota => pos_integer()}) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-doc """
A pipe whose two ends the calling process holds: `{ok, Read, Write}`, or
`{error, enfile}` at the session's quota and `{error, enomem}` when the
objects cannot be made.
""".
-spec pipe() -> {ok, term(), term()} | {error, enfile | enomem}.
pipe() ->
    gen_server:call(?MODULE, {pipe, {process, self()}, []}).

-doc """
An end for the process `Child` of the same kind as `End`, an end the
calling process holds, as a child inherits one: `{ok, ChildEnd}`, which
only `Child` may use and which the caller hands to it, or `{error,
ebadf}` for an end the caller does not hold, `{error, enfile}` at the
session's quota and `{error, enomem}` when the objects cannot be made
or `Child` has exited.
""".
-spec inherit(term(), pid()) -> {ok, term()} | {error, ebadf | enfile | enomem}.
inherit(End, Child) when is_pid(Child), node(Child) =:= node() ->
    gen_server:call(?MODULE, {inherit, {process, self()}, End, {process, Child}}).

-doc """
A program handler's request or notice for its program, `Event` an event
of erx_pipe:step/2 that names `{program, Pid}`: the step's reply for a
request (`pipe`, `inherit`, `exec`), each end a `{pipe_hand, Number,
Term}` for the handler's port driver to take, and `ok` for a notice
(`closed`, `drained`, `install_failed`); `{error, badarg}` when the
caller does not speak for the program the event names.
""".
-spec forward(erx_pipe:event()) -> term().
forward(Event) when is_tuple(Event) ->
    gen_server:call(?MODULE, {forward, Event}, infinity).

-doc """
Reads at most `Max` bytes from a read end the calling process holds,
waiting at most `Timeout` milliseconds: the bytes, `eof` once no write
end remains and every byte has been read, `{error, eio}` once the pipe is
lost, or `{error, timeout}`.
""".
-spec read(term(), pos_integer(), timeout()) -> binary() | eof | {error, eio | timeout}.
read(End, Max, Timeout) ->
    case retry(fun() -> erx_pipe_nif:read(End, Max) end, Timeout) of
        {error, timeout} ->
            %% A read of 0 bytes ends the wait the last call left in
            %% progress, so the end's peers stop ringing it.
            _ = erx_pipe_nif:read(End, 0),
            {error, timeout};
        Result ->
            Result
    end.

-doc """
Writes `Bin` to a write end the calling process holds, waiting for room
at most `Timeout` milliseconds: `ok`, `{error, epipe}` once no read end
remains or the pipe is lost, or `{error, timeout}`.
""".
-spec write(term(), iodata(), timeout()) -> ok | {error, epipe | timeout}.
write(End, Data, Timeout) ->
    write_rest(End, iolist_to_binary(Data), Timeout).

-doc "Closes an end the calling process holds; the server learns of it.".
-spec close(term()) -> ok.
close(End) ->
    erx_pipe_nif:close(End).

write_rest(_End, <<>>, _Timeout) ->
    ok;
write_rest(End, Bin, Timeout) ->
    case retry(fun() -> erx_pipe_nif:write(End, Bin) end, Timeout) of
        N when is_integer(N) -> write_rest(End, binary:part(Bin, N, byte_size(Bin) - N), Timeout);
        Other -> Other
    end.

%% Calls the NIF until it does not return would_block, waiting for a
%% message that may change the answer between calls.
retry(Call, Timeout) ->
    case Call() of
        would_block ->
            receive
                {erx_pipe_ready, _, _} -> retry(Call, Timeout);
                {pipe_report, _} -> retry(Call, Timeout);
                {pipe_server_lost, _} -> retry(Call, Timeout)
            after Timeout ->
                {error, timeout}
            end;
        Result ->
            Result
    end.

%% ---------------------------------------------------------------------
%% The server

init(Opts) ->
    Nif = maps:get(nif, Opts, erx_pipe_nif),
    %% Above every pipe an earlier server made over this NIF.
    First = Nif:pipes_made() + 1,
    {ok, #srv{nif = Nif, pipes = erx_pipe:new((maps:with([quota], Opts))#{first_pipe => First})}}.

%% A reply's ends go to the holder named first in its target: the caller
%% for a pipe, the child for an inherited end.
handle_call({pipe, {process, Pid} = Holder, Flags}, {Pid, _} = From, S) when node(Pid) =:= node() ->
    {noreply, run({pipe, Holder, Flags}, {Holder, From}, S)};
handle_call({inherit, {process, Pid} = Holder, EndRes, {process, Child} = ChildHolder},
            {Pid, _} = From, #srv{ends = Ends} = S)
  when node(Pid) =:= node(), node(Child) =:= node() ->
    case [Key || Key := {Owner, Res} <- Ends, Owner =:= Pid, Res =:= EndRes] of
        [{Pipe, End}] ->
            {noreply, run({inherit, Holder, Pipe, End, ChildHolder}, {ChildHolder, From}, S)};
        [] ->
            {reply, {error, ebadf}, S}
    end;
handle_call({forward, Event}, {Caller, _} = From, #srv{nif = Nif} = S) ->
    case speaker(Event) of
        {program, Pid} = Program when is_integer(Pid), Pid > 0 ->
            case Nif:holder_owner(Pid) of
                {ok, Caller} -> forwarded(Event, Program, From, S);
                _ -> {reply, {error, badarg}, S}
            end;
        _ ->
            {reply, {error, badarg}, S}
    end;
handle_call(_Request, _From, S) ->
    {reply, {error, einval}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% The NIF's notices name the end's owner as the holder.
handle_info({closed, {process, _}, _, _} = Event, S) ->
    {noreply, forget_end(Event, run(Event, none, S))};
handle_info({drained, {process, _}, _, _, _} = Event, S) ->
    {noreply, run(Event, none, S)};
%% The NIF's word that no image of the program runs: its ends are gone.
handle_info({erx_pipe_holder_gone, Pid}, S) when is_integer(Pid), Pid > 0 ->
    {noreply, run({gone, {program, Pid}}, none, S)};
handle_info(_Msg, S) ->
    {noreply, S}.

%% The holder whose sender may send an event: its holder, or for an
%% inherit naming a program child, the child, whose handler asks for it.
speaker({inherit, _Starter, _Pipe, _End, {program, _} = Child}) -> Child;
speaker(Event) when tuple_size(Event) >= 2 -> element(2, Event);
speaker(_) -> none.

%% A request's reply goes to the program it names, as a hand-off to its
%% handler, the caller; a notice is answered ok once it has run.
forwarded({pipe, Program, _} = Event, Program, From, S) ->
    {noreply, run(Event, {Program, From}, S)};
forwarded({inherit, _, _, _, Child} = Event, Child, From, S) ->
    {noreply, run(Event, {Child, From}, S)};
forwarded({exec, Program, _} = Event, Program, From, S) ->
    {noreply, run(Event, {Program, From}, S)};
forwarded(Event, _Program, _From, S) when element(1, Event) =:= closed;
                                           element(1, Event) =:= drained;
                                           element(1, Event) =:= install_failed ->
    {reply, ok, run(Event, none, S)};
forwarded(_Event, _Program, _From, S) ->
    {reply, {error, badarg}, S}.

%% Runs one event's step and performs its actions; an install that fails
%% comes back as an event of its own, run after the step's other actions.
%% To is where a request's reply goes, {Holder, From}, or none for a notice.
run(Event, To, #srv{pipes = Pipes} = S) ->
    {Next, Actions} = erx_pipe:step(Pipes, Event),
    {Makes, Rest} = lists:partition(fun is_make/1, Actions),
    case make_all(Makes, S, []) of
        {ok, S1} ->
            {S2, Later} = perform(Rest, To, S1#srv{pipes = Next}, []),
            lists:foldl(fun(E, Acc) -> run(E, none, Acc) end, S2, Later);
        {error, Made} ->
            lists:foreach(fun(Obj) -> (S#srv.nif):close(Obj) end, Made),
            reply(To, {error, enomem}),
            S
    end.

is_make(Action) ->
    lists:member(element(1, Action), [make_lock, make_lane, make_bell]).

make_all([], S, _Made) ->
    {ok, S};
make_all([Make | Rest], #srv{nif = Nif, objects = Objects} = S, Made) ->
    case make(Nif, Make) of
        {ok, Named} ->
            make_all(Rest, S#srv{objects = maps:merge(Objects, maps:from_list(Named))},
                     [Obj || {_, Obj} <- Named] ++ Made);
        {error, _} ->
            {error, Made}
    end.

make(Nif, {make_lock, {lock, Pipe} = Lock}) ->
    case Nif:make_lock(Pipe) of
        {ok, Obj} -> {ok, [{Lock, Obj}]};
        Error -> Error
    end;
make(Nif, {make_lane, Ring, RPage, Size}) ->
    case Nif:make_lane(Size) of
        {ok, RingObj, RPageObj} -> {ok, [{Ring, RingObj}, {RPage, RPageObj}]};
        Error -> Error
    end;
make(Nif, {make_bell, {bell, Pipe, End} = Bell, {process, Pid}, registered}) ->
    case Nif:make_bell(Pid, Pipe, End) of
        {ok, Obj} -> {ok, [{Bell, Obj}]};
        Error -> Error
    end;
%% A program's doorbell is made unbound; its label goes into the hand-off
%% that gives the end, for the program's port driver to bind it with.
make(Nif, {make_bell, {bell, Pipe, End} = Bell, {program, _} = Program, _Label}) ->
    case Nif:make_bell(Program, Pipe, End) of
        {ok, Obj} -> {ok, [{Bell, Obj}]};
        Error -> Error
    end.

perform([], _To, S, Later) ->
    {S, lists:reverse(Later)};
perform([Action | Rest], To, S, Later) ->
    {S1, More} = perform_one(Action, To, S),
    perform(Rest, To, S1, lists:reverse(More, Later)).

perform_one({store_wends, Lock, Wends}, _To, #srv{nif = Nif} = S) ->
    ok = Nif:store_wends(object(Lock, S), Wends),
    {S, []};
perform_one({free_lock, Lock, Rix}, _To, #srv{nif = Nif} = S) ->
    ok = Nif:free_lock(object(Lock, S), Rix),
    {S, []};
perform_one({close, Name}, _To, #srv{nif = Nif, objects = Objects} = S) ->
    ok = Nif:close(object(Name, S)),
    {S#srv{objects = maps:remove(Name, Objects)}, []};
perform_one({report, {process, Pid} = Holder, Report}, _To, #srv{nif = Nif} = S) ->
    Pipe = element(2, Report),
    End = element(3, Report),
    case maps:find({Pipe, End}, S#srv.ends) of
        error ->
            %% The end's owner closed it or exited, and its notice is on
            %% its way: nothing reaches a holder that has let go.
            {S, []};
        {ok, {_Owner, EndRes}} ->
            case {Nif:apply(EndRes, resolve(Report, S)), erx_pipe:copies(Report)} of
                {ok, _} ->
                    Pid ! {pipe_report, Report},
                    {S, []};
                {{error, _}, [_ | _]} ->
                    {S, [{install_failed, Holder, Pipe, End}]};
                {{error, Reason}, []} ->
                    %% A report that installs nothing cannot fail but on a
                    %% NIF bug; another event for it would loop on
                    %% pipe_lost, which installs nothing either.
                    logger:error("erx_pipe_srv: report ~0p to ~0p not applied: ~0p",
                                 [Report, Pid, Reason]),
                    {S, []}
            end
    end;
perform_one({report, {program, Pid} = Holder, Report}, _To, #srv{nif = Nif} = S) ->
    case Nif:holder_owner(Pid) of
        none ->
            %% The program's gone is on its way and covers the end.
            {S, []};
        {ok, Handler} ->
            case erx_pipe:copies(Report) of
                [] ->
                    Handler ! {pipe_report, Pid, Report},
                    {S, []};
                Copies ->
                    case Nif:hand_make(Pid, [{resolve(Copies, S), none}]) of
                        {ok, [Number]} ->
                            Handler ! {pipe_report, Pid, {pipe_hand, Number, hand_term(Report, Copies)}},
                            {S, []};
                        none ->
                            {S, []};
                        {error, _} ->
                            {S, [{install_failed, Holder, element(2, Report), element(3, Report)}]}
                    end
            end
    end;
perform_one({reply, Reply}, To, S) ->
    reply_to(Reply, To, S).

%% A reply that names descriptors opens the session process's ends; an
%% open that fails undoes every end of the reply with `closed`.
reply_to(_Reply, none, S) ->
    {S, []};
reply_to({ok, _, _} = Reply, {{process, Owner}, From}, S) ->
    open_ends(Reply, Owner, From, S);
reply_to({ok, {pipe, _, _, _}} = Reply, {{process, Owner}, From}, S) ->
    open_ends(Reply, Owner, From, S);
reply_to({ok, _, _} = Reply, {{program, Pid}, From}, S) ->
    hand_reply(Reply, Pid, From, S);
reply_to({ok, _} = Reply, {{program, Pid}, From}, S) ->
    hand_reply(Reply, Pid, From, S);
reply_to(Reply, To, S) ->
    reply(To, Reply),
    {S, []}.

%% A reply to a program's handler: each descriptor becomes a hand-off the
%% NIF holds for the handler, made all at once, and the handler is told
%% its number. With no entry for the program its gone is on its way and
%% covers the ends; an allocation that fails closes them, as for a
%% process's ends that cannot be opened.
hand_reply({ok, []} = Reply, _Pid, From, S) ->
    %% An exec that keeps no end hands nothing off.
    gen_server:reply(From, Reply),
    {S, []};
hand_reply(Reply, Pid, From, #srv{nif = Nif} = S) ->
    Descriptors = reply_descriptors(Reply),
    Hands = [{resolve(erx_pipe:copies(D), S), own_bell(D, S)} || D <- Descriptors],
    case Nif:hand_make(Pid, Hands) of
        {ok, Numbers} ->
            Named = maps:from_list(lists:zip(Descriptors, Numbers)),
            gen_server:reply(From, name_hands(Reply, Named)),
            {S, []};
        none ->
            gen_server:reply(From, {error, ebadf}),
            {S, []};
        {error, _} ->
            gen_server:reply(From, {error, enomem}),
            {S, [{closed, {program, Pid}, P, E} || {pipe, _, {P, E}, _} <- Descriptors]}
    end.

reply_descriptors({ok, D1, D2}) -> [D1, D2];
reply_descriptors({ok, Kept}) when is_list(Kept) -> [D || {_, D} <- Kept];
reply_descriptors({ok, D}) -> [D].

%% The reply with each descriptor in place of its hand-off.
name_hands({ok, D1, D2}, Named) -> {ok, hand(D1, Named), hand(D2, Named)};
name_hands({ok, Kept}, Named) when is_list(Kept) -> {ok, [{Key, hand(D, Named)} || {Key, D} <- Kept]};
name_hands({ok, D}, Named) -> {ok, hand(D, Named)}.

hand(D, Named) ->
    {pipe_hand, maps:get(D, Named), hand_term(D, erx_pipe:copies(D))}.

%% The end's own doorbell and its label in the program's group.
own_bell({pipe, _, {Pipe, End}, _}, S) ->
    {object({bell, Pipe, End}, S), erx_pipe:label(Pipe, End)}.

%% Term with each object Copies lists written {hand, I}, I its place in
%% the list from 1; each object appears in a descriptor or report once.
hand_term(Term, Copies) ->
    Places = maps:from_list(lists:zip([Obj || {Obj, _} <- Copies], lists:seq(1, length(Copies)))),
    place(Term, Places).

place(Term, Places) when is_map_key(Term, Places) ->
    {hand, maps:get(Term, Places)};
place(Term, Places) when is_tuple(Term) ->
    list_to_tuple(place(tuple_to_list(Term), Places));
place(Term, Places) when is_list(Term) ->
    [place(T, Places) || T <- Term];
place(Term, Places) when is_map(Term) ->
    maps:map(fun(_, V) -> place(V, Places) end, Term);
place(Term, _Places) ->
    Term.

open_ends(Reply, Pid, From, #srv{nif = Nif} = S) ->
    [ok | Descriptors] = tuple_to_list(Reply),
    Opened = [{Pipe, End, Nif:open_end(Pid, self(), resolve(D, S))}
              || {pipe, _, {Pipe, End}, _} = D <- Descriptors],
    case [R || {_, _, {ok, R}} <- Opened] of
        Ends when length(Ends) =:= length(Opened) ->
            gen_server:reply(From, list_to_tuple([ok | Ends])),
            {S#srv{ends = maps:merge(S#srv.ends,
                                     maps:from_list([{{P, E}, {Pid, R}} || {P, E, {ok, R}} <- Opened]))},
             []};
        Ends ->
            %% A closed end tells the server itself; the others never opened.
            lists:foreach(fun(R) -> ok = Nif:close(R) end, Ends),
            gen_server:reply(From, {error, enomem}),
            {S, [{closed, {process, Pid}, P, E} || {P, E, Result} <- Opened,
                                                   element(1, Result) =/= ok]}
    end.

%% The end is forgotten only on its owner's notice, as the step forgets
%% it only then.
forget_end({closed, {process, Pid}, Pipe, End}, #srv{ends = Ends} = S) ->
    case Ends of
        #{{Pipe, End} := {Pid, _}} -> S#srv{ends = maps:remove({Pipe, End}, Ends)};
        _ -> S
    end.

%% The server's capabilities in place of the names a descriptor or a
%% report gives its objects.
resolve(Term, #srv{objects = Objects}) ->
    resolve_term(Term, Objects).

resolve_term(Term, Objects) when is_map_key(Term, Objects) ->
    maps:get(Term, Objects);
resolve_term(Term, Objects) when is_tuple(Term) ->
    list_to_tuple(resolve_term(tuple_to_list(Term), Objects));
resolve_term(Term, Objects) when is_list(Term) ->
    [resolve_term(T, Objects) || T <- Term];
resolve_term(Term, Objects) when is_map(Term) ->
    maps:map(fun(_, V) -> resolve_term(V, Objects) end, Term);
resolve_term(Term, _Objects) ->
    Term.

object(Name, #srv{objects = Objects}) ->
    maps:get(Name, Objects).

reply(none, _Reply) ->
    ok;
reply({_Owner, From}, Reply) ->
    gen_server:reply(From, Reply).
