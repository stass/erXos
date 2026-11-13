%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pixels).
-moduledoc """
A client domain's one allocator of its pixel areas (docs/design-display.md,
"The pixel area", A client's buffers), registered locally as `erx_pixels`.
For each display whose area it has open it keeps an `erx_pixels_core` and
performs that core's effects: it zeroes a range before the range rejoins the
free list, makes each lease of a range for the range's owner, and answers the
lends that waited.

A range belongs to the process that allocated it, which this process
monitors, and goes back to the free list once its owner has exited and no
lease of it is outstanding; there is no `free`. An area is opened at the
first `alloc/2` that names its display, and let go once no range of it is
live, so a lost connection's end waits for its last program's return and for
nothing else.

The allocator is never restarted over an area: its state is the only record
of which ranges programs still map. `erx_display_sup` starts it as a
temporary, significant child, so its end ends the domain, whose next start
has new, zeroed areas.

Every request is checked on arrival, whoever sends it, and a `'DOWN'` counts
only with the reference of this process's own monitor, so nothing another
process sends ends this one or frees a live owner's range. The caller named in
a call's `From` is taken as given: that check is not an authority, and a lease
made for an impersonated owner can be taken only by that owner's own port.
""".
-behaviour(gen_server).

-export([start_link/0, alloc/2, lend/2, unlend/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-define(MAX_U64, 16#ffffffffffffffff).
-define(IS_PEER(Peer), (is_integer(Peer) andalso Peer > 0)).

%% areas: each open area by its display's domain id, with its core. leases:
%% the display of each outstanding lease and the reference its lend carried,
%% which a return must carry too: a lease's number alone is guessable.
%% owners: the processes this one monitors, the owners of live ranges.
-record(state, {areas = #{} :: #{pos_integer() => {erx_area:area(), erx_pixels_core:core()}},
                leases = #{} :: #{pos_integer() => {pos_integer(), reference()}},
                owners = #{} :: #{pid() => reference()}}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
A range of whole pages, at least Bytes, of the pixel area this domain shares
with the display domain Peer, zeroed and owned by the caller: `{ok, Offset}`,
`{error, enomem}` when no free run is long enough, or `{error, none}` when the
domain has no area to Peer.
""".
-spec alloc(pos_integer(), pos_integer()) -> {ok, non_neg_integer()} | {error, enomem | none}.
alloc(Peer, Bytes) when is_integer(Peer), Peer > 0, is_integer(Bytes), Bytes > 0 ->
    gen_server:call(?MODULE, {alloc, Peer, Bytes}, infinity).

-doc """
A lease of the caller's whole range at Offset of Peer's area, with the caller
as its holder, for `erx_program:start/1`: `{ok, Lease, Pages}`. While an
earlier lease of the range is outstanding the call waits for its return.
`{error, einval}` for an Offset that starts no range of the caller's in
Peer's area.
""".
-spec lend(pos_integer(), non_neg_integer()) -> {ok, pos_integer(), pos_integer()} | {error, einval | noproc | enomem}.
lend(Peer, Offset) when is_integer(Peer), Peer > 0, is_integer(Offset), Offset >= 0 ->
    gen_server:call(?MODULE, {lend, Peer, Offset}, infinity).

-doc """
Gives back Lease, a lease of the caller's, if no program port has taken it;
does nothing to one taken, returned or not the caller's.
""".
-spec unlend(pos_integer()) -> ok.
unlend(Lease) when is_integer(Lease), Lease > 0, Lease =< ?MAX_U64 ->
    gen_server:call(?MODULE, {unlend, Lease}, infinity).

init([]) ->
    {ok, #state{}}.

handle_call({alloc, Peer, Bytes}, {Owner, _}, State) when ?IS_PEER(Peer), is_integer(Bytes), Bytes > 0 ->
    case area(Peer, State) of
        {ok, Area, Core} ->
            {Reply, Next} = alloc(Peer, Area, Core, Owner, Bytes, State),
            settled({reply, Reply}, [Peer], Next);
        none ->
            {reply, {error, none}, State}
    end;
handle_call({lend, Peer, Offset}, {Owner, _} = From, #state{areas = Areas} = State)
  when ?IS_PEER(Peer), is_integer(Offset), Offset >= 0 ->
    case maps:find(Peer, Areas) of
        {ok, {Area, Core}} ->
            {noreply, perform(Peer, Area, erx_pixels_core:lend(Core, Owner, Offset, From), State)};
        error ->
            {reply, {error, einval}, State}
    end;
handle_call({unlend, Lease}, {Caller, _}, State) when is_integer(Lease), Lease > 0, Lease =< ?MAX_U64 ->
    case holder(Lease, State) of
        {ok, Caller} -> ok = erx_area:unlend(Lease);
        _NotTheCallers -> ok
    end,
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({erx_area_returned, Tag, Lease}, #state{areas = Areas, leases = Leases} = State) ->
    case Leases of
        #{Lease := {Peer, Tag}} ->
            {Area, Core} = maps:get(Peer, Areas),
            Rest = maps:remove(Lease, Leases),
            Next = perform(Peer, Area, erx_pixels_core:returned(Core, Lease), State#state{leases = Rest}),
            settled(noreply, [Peer], Next);
        #{} ->
            {noreply, State}
    end;
handle_info({'DOWN', Ref, process, Owner, _}, #state{areas = Areas, owners = Owners} = State) ->
    case Owners of
        #{Owner := Ref} ->
            Gone = State#state{owners = maps:remove(Owner, Owners)},
            Next = maps:fold(fun(Peer, {Area, Core}, Acc) ->
                                     perform(Peer, Area, erx_pixels_core:owner_down(Core, Owner), Acc)
                             end, Gone, Areas),
            settled(noreply, maps:keys(Areas), Next);
        #{} ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% An area let go is unmapped once its last term is collected: collect now,
%% after the callback that dropped it has returned.
handle_continue(collect, State) ->
    erlang:garbage_collect(),
    {noreply, State}.

%% The owner of the range Lease is an outstanding lease of, or error.
holder(Lease, #state{areas = Areas, leases = Leases}) ->
    case maps:find(Lease, Leases) of
        {ok, {Peer, _Tag}} -> erx_pixels_core:holder(element(2, maps:get(Peer, Areas)), Lease);
        error -> error
    end.

%% Peer's open area, or the area opened now with a fresh core.
area(Peer, #state{areas = Areas}) ->
    case maps:find(Peer, Areas) of
        {ok, {Area, Core}} ->
            {ok, Area, Core};
        error ->
            case erx_area:open(Peer) of
                {ok, Area, Bytes} -> {ok, Area, erx_pixels_core:new(Bytes)};
                {error, _} -> none
            end
    end.

alloc(Peer, Area, Core, Owner, Bytes, #state{areas = Areas, owners = Owners} = State) ->
    case erx_pixels_core:alloc(Core, Owner, Bytes) of
        {ok, Offset, Next} ->
            Monitored = case Owners of
                            #{Owner := _} -> Owners;
                            #{} -> Owners#{Owner => monitor(process, Owner)}
                        end,
            {{ok, Offset}, State#state{areas = Areas#{Peer => {Area, Next}}, owners = Monitored}};
        {error, enomem} ->
            {{error, enomem}, State#state{areas = Areas#{Peer => {Area, Core}}}}
    end.

%% Performs a core's effects in order, each follow-up's effects before the
%% rest, and keeps the core they end with as Peer's.
perform(Peer, Area, {Core, Effects}, State) ->
    {Last, #state{areas = Areas} = Next} = run(Effects, Peer, Area, Core, State),
    Next#state{areas = Areas#{Peer => {Area, Last}}}.

run(Effects, Peer, Area, Core, State) ->
    lists:foldl(fun(Effect, {C, S}) -> effect(Effect, Peer, Area, C, S) end, {Core, State}, Effects).

effect({reply, From, Reply}, _Peer, _Area, Core, State) ->
    gen_server:reply(From, Reply),
    {Core, State};
effect({zero, Offset, Pages}, _Peer, Area, Core, State) ->
    ok = erx_area:zero(Area, Offset, Pages),
    {erx_pixels_core:zeroed(Core, Offset, Pages), State};
effect({lend, Offset, Pages, Owner}, Peer, Area, Core, #state{leases = Leases} = State) ->
    Tag = make_ref(),
    Answer = erx_area:lend(Area, Offset, Pages, Owner, Tag),
    Kept = case Answer of
               {ok, Lease} -> State#state{leases = Leases#{Lease => {Peer, Tag}}};
               {error, _} -> State
           end,
    {Next, Effects} = erx_pixels_core:lent(Core, Offset, Answer),
    run(Effects, Peer, Area, Next, Kept).

%% The callback's answer, Answer being {reply, Reply} or noreply, once each of
%% Peers' areas that no live range needs is let go; a let-go area is collected
%% after the callback returns (handle_continue/2).
settled(Answer, Peers, State) ->
    {LetGo, Next} = let_go(Peers, State),
    Continue = [{continue, collect} || LetGo],
    case Answer of
        {reply, Reply} -> list_to_tuple([reply, Reply, Next | Continue]);
        noreply -> list_to_tuple([noreply, Next | Continue])
    end.

%% Lets go of each of Peers' areas that no live range needs.
let_go(Peers, #state{areas = Areas} = State) ->
    Idle = [Peer || Peer <- Peers, erx_pixels_core:idle(element(2, maps:get(Peer, Areas)))],
    {Idle =/= [], State#state{areas = maps:without(Idle, Areas)}}.
