%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_input_follower).
-moduledoc """
The display's follower of its input grants (docs/design-display.md, "The
display device"): one supervised process that keeps one erx_input_reader
running for each file of each input tree the domain is granted, a tree of
another domain's service of the `input` interface (abi/services/input.txt),
such as the USB domain's HID devices.

It reads as it starts, and again whenever the domain's connection agent
answers its request, in this order: the registry's generation
(erx_facets:generation/0), the domain's grants of the input interface
(erx:granted/1) and the installed facets; it then asks for word of an
installation past the generation it read first (erx_facets:changed/1), and
keeps that one request outstanding until the answer comes (docs/design-system.md,
"Waiting for a grant"). Read in another order, a ready answer that landed
between two reads could leave it waiting for an installation that never
comes. The names arrive with the domain's ready answer, after the display's
applications start, so a first read that finds none is normal.

It keeps, for each name, the facet it last followed. For each name whose
installed facet is another, it stops the tree's lister or readers if it
still follows the old facet, then resolves the grant once
(erx_facets:file_grant/2, read-only, on the tree the registry holds with the
facet), monitors the grant's process, and lists the tree in a linked
lister process (erx_input_reader:files/1), so a tree whose server is slow
to answer holds up no other tree. With the listing it starts one reader,
linked to it, for each file, on that same grant, named `Facet/File` to
the router. A listing that fails, or a lister that ends without one, is
tried again RETRY_MS later on the same grant, its monitor kept: a retry of
the server's answer, since an installation does not say that a server
already installed has become able to answer. A retry that comes once the
grant has ended, or once another facet of the name is followed, is dropped.

When the grant's process ends, the follower stops that tree's lister or
readers and waits for each to end before it does anything else, so no
reader of the old grant runs beside a replacement (the router keys each
source by its pid, so it releases an old reader's keys whenever its monitor
fires), and keeps the ended facet as the one it last followed: the
installation of the server's new grant starts the tree again, whether it
comes before or after that end, and no other installation lists the ended
facet again. A reader that ends by itself, at its file's end or a failed
read, is not replaced: only a new grant starts new readers. The follower
traps exits, so a reader's end never ends it, and stops every reader as it
terminates; the agent's end, which ends the runtime, ends it too.

Its effects come as an environment (env/0), so a host test drives it over
model grants, readers and agent.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([env/0]).

-include("generated/erx_abi.hrl").

%% How long after a failed listing the tree is listed again on the same grant.
-define(RETRY_MS, 1000).

-doc """
What the follower acts through: `generation`, the registry's generation;
`granted`, the names of the domain's input grants; `changed`, a request for
word of an installation past a generation, as erx_facets:changed/1 makes it;
`resolve`, a name's grant, or an error while its facet is not installed;
`list`, a tree's files; and `start`, one reader of a file, by its device
name, grant and file name, linked to the caller.
""".
-type env() :: #{generation := fun(() -> non_neg_integer()),
                 granted := fun(() -> [atom()]),
                 changed := fun((non_neg_integer()) -> gen:request_id() | {error, noproc}),
                 resolve := fun((atom()) -> {ok, erx_input_reader:grant()} | {error, term()}),
                 list := fun((erx_input_reader:grant()) -> {ok, [binary()]} | {error, term()}),
                 start := fun((binary(), erx_input_reader:grant(), binary()) -> pid())}.

%% A tree by the grant last followed, whose pid is the facet: while the grant lasts, the
%% monitor on its process and its lister while the tree is listed, the timer's tag while
%% a failed listing waits to be tried again, or its live readers once it is listed; once
%% the grant has ended, only the grant.
-type tree() :: #{grant := erx_input_reader:grant(), monitor := reference(),
                  phase := {listing, pid()} | {retrying, reference()} | {reading, [pid()]}}
              | #{grant := erx_input_reader:grant(), phase := ended}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{generation => fun erx_facets:generation/0,
                 granted => fun() -> erx:granted(?ERX_SERVICE_INPUT) end,
                 changed => fun erx_facets:changed/1,
                 resolve => fun(Name) -> erx_facets:file_grant(Name, ro) end,
                 list => fun erx_input_reader:files/1,
                 start => fun(Device, Grant, File) ->
                                  erx_input_reader:start_link(Device, erx_input_reader:opener(Grant, File))
                          end}).

-doc "The follower over Env, for a host test.".
-spec start_link(env()) -> {ok, pid()} | {error, term()}.
start_link(Env) ->
    gen_server:start_link(?MODULE, Env, []).

init(Env) ->
    process_flag(trap_exit, true),
    {ok, #{env => Env, trees => #{}, request => none}, {continue, look}}.

handle_continue(look, State) ->
    {noreply, look(State)}.

handle_call(_Request, _From, State) ->
    {reply, {error, enotsup}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% The agent's answer to the one request outstanding says to read again; its end ends
%% the runtime, and the follower with it.
handle_info(Message, #{request := Request} = State) when Request =/= none ->
    case gen_server:check_response(Message, Request) of
        {reply, ok} -> {noreply, look(State)};
        no_reply -> {noreply, info(Message, State)};
        {error, {Reason, _Agent}} -> {stop, Reason, State}
    end;
handle_info(Message, State) ->
    {noreply, info(Message, State)}.

terminate(_Reason, #{trees := Trees}) ->
    maps:foreach(fun(_Name, #{phase := Phase}) -> stop(Phase) end, Trees).

info({listed, Lister, Listing}, State) ->
    on_tree(fun(#{phase := Phase}) -> Phase =:= {listing, Lister} end,
            fun(Name, Tree, S) -> listed(Name, Tree, Listing, S) end, State);
info({relist, Tag}, State) ->
    on_tree(fun(#{phase := Phase}) -> Phase =:= {retrying, Tag} end, fun lister/3, State);
info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    on_tree(fun(#{monitor := M}) -> M =:= Monitor; (#{}) -> false end, fun ended/3, State);
info({'EXIT', Pid, Reason}, State) ->
    %% A lister's listing comes before its exit, since both are its signals to the
    %% follower, so a lister that ends while its tree is still listed failed to list it.
    Listed = on_tree(fun(#{phase := Phase}) -> Phase =:= {listing, Pid} end,
                     fun(Name, Tree, S) -> listed(Name, Tree, {error, {lister, Reason}}, S) end, State),
    on_tree(fun(#{phase := Phase}) -> reads(Pid, Phase) end, fun(Name, Tree, S) -> reader_ended(Name, Tree, Pid, S) end,
            Listed);
info(_Message, State) ->
    State.

%% One read of the registry, in the design's order, then the request for word of an
%% installation past the generation read first. Where the runtime is no node no agent
%% runs, no installation ever comes, and the follower asks nothing.
look(#{env := #{generation := Generation, granted := Granted, changed := Changed}} = State) ->
    Seen = Generation(),
    Names = Granted(),
    Followed = lists:foldl(fun follow/2, State, Names),
    case Changed(Seen) of
        {error, noproc} -> Followed#{request := none};
        Request -> Followed#{request := Request}
    end.

%% Follows the tree Name when its installed facet is another than the one last followed:
%% the old grant's processes stopped, the new grant resolved once, monitored, and listed.
follow(Name, #{env := #{resolve := Resolve}, trees := Trees} = State) ->
    case Resolve(Name) of
        {ok, {Facet, _Tree, ro} = Grant} ->
            case Trees of
                #{Name := #{grant := {Facet, _, ro}}} ->
                    State;
                #{} ->
                    Monitor = erlang:monitor(process, Facet),
                    lister(Name, #{grant => Grant, monitor => Monitor}, unfollow(Name, State))
            end;
        {error, _} ->
            State
    end.

%% Lists the tree Name on its grant in a lister linked to the follower.
lister(Name, #{grant := Grant} = Tree, #{env := #{list := List}, trees := Trees} = State) ->
    Follower = self(),
    Lister = spawn_link(fun() -> Follower ! {listed, self(), List(Grant)} end),
    State#{trees := Trees#{Name => Tree#{phase => {listing, Lister}}}}.

%% The tree Name listed: one reader for each file, on the tree's grant, or with a failed
%% listing, the tree listed again RETRY_MS later on the same grant.
-spec listed(atom(), tree(), {ok, [binary()]} | {error, term()}, State) -> State when State :: map().
listed(Name, #{grant := Grant} = Tree, {ok, Files}, #{env := #{start := Start}, trees := Trees} = State) ->
    Prefix = <<(atom_to_binary(Name))/binary, $/>>,
    Readers = [Start(<<Prefix/binary, File/binary>>, Grant, File) || File <- Files],
    State#{trees := Trees#{Name := Tree#{phase := {reading, Readers}}}};
listed(Name, Tree, {error, Reason}, #{trees := Trees} = State) ->
    _ = erx_log:debug_text(["erx_input_follower: ", atom_to_binary(Name), " not listed: ",
                            io_lib:format("~0p", [Reason])]),
    Tag = make_ref(),
    _ = erlang:send_after(?RETRY_MS, self(), {relist, Tag}),
    State#{trees := Trees#{Name := Tree#{phase := {retrying, Tag}}}}.

%% The reader Pid of the tree Name ended by itself, at its file's end or a failed read: it
%% is not replaced, and no longer stopped with its tree.
reader_ended(Name, #{phase := {reading, Readers}} = Tree, Pid, #{trees := Trees} = State) ->
    State#{trees := Trees#{Name := Tree#{phase := {reading, lists:delete(Pid, Readers)}}}}.

%% The tree Name's grant ended: its lister or readers stopped, and the grant kept as the
%% one last followed, so only another facet of the name follows the tree again.
ended(Name, #{grant := Grant, phase := Phase}, #{trees := Trees} = State) ->
    stop(Phase),
    State#{trees := Trees#{Name := #{grant => Grant, phase => ended}}}.

%% The tree Name no longer followed, its grant's processes stopped and its monitor taken
%% down, as another facet of the name replaces it.
unfollow(Name, #{trees := Trees} = State) ->
    case Trees of
        #{Name := #{monitor := Monitor, phase := Phase}} ->
            true = erlang:demonitor(Monitor, [flush]),
            stop(Phase);
        #{} ->
            ok
    end,
    State#{trees := maps:remove(Name, Trees)}.

%% Stops the processes of a tree's phase and returns once each has ended: each is linked
%% to the follower and its exit has not been taken, since a taken exit removes a reader
%% from its tree and moves a lister's tree on, so exactly one exit message comes.
stop({listing, Lister}) -> stop_all([Lister]);
stop({reading, Readers}) -> stop_all(Readers);
stop({retrying, _Tag}) -> ok;
stop(ended) -> ok.

stop_all(Pids) ->
    lists:foreach(fun(Pid) -> exit(Pid, shutdown) end, Pids),
    lists:foreach(fun(Pid) -> receive {'EXIT', Pid, _} -> ok end end, Pids).

reads(Pid, {reading, Readers}) -> lists:member(Pid, Readers);
reads(_Pid, _Phase) -> false.

%% Applies Fun to the one followed tree Match picks, by its name, or leaves State as it is
%% when none does, as for a message about a tree already forgotten or a grant replaced.
on_tree(Match, Fun, #{trees := Trees} = State) ->
    case [{Name, Tree} || Name := Tree <- Trees, Match(Tree)] of
        [{Name, Tree}] -> Fun(Name, Tree, State);
        [] -> State
    end.
