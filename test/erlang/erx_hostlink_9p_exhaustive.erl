%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_9p_exhaustive).
-moduledoc """
The exhaustive test of the host link's 9P bridge core, `erx_hostlink_9p`, run
by test/host/erx_hostlink_9p_exhaustive_test.rb on stock's emulator.

It enumerates every interleaving of a host and one grant over a small bound,
from a session with fid 1 attached: the host sends reads, flushes of a tag
in use (at most two flushes for each request, a flush of a flush counted
for the request it ends in) and one `version` in the session, within a
budget of messages
and always on its lowest free tag; the grant answers any message it holds in
any order, a request well formed or malformed, a flush `ok`, refused or
malformed; and the grant may end once. Each configuration sets the bridge's
bounds small, so the bound paths are part of the enumeration.

On every trace it checks, as the host and the grant see the bridge:

* (a) no tag is answered while not in use, so none twice (`tag_not_in_use`);
* (b) whenever the grant holds nothing, every message the bridge admitted is
  answered (`unanswered`);
* (c) a flush is answered after the message it names, and after every
  earlier flush of the same request (`flush_before_its_target`,
  `flush_out_of_order`); a request a flush's answer leaves unanswered was
  abandoned, which only the grant may do, by answering a flush of it `ok`
  (`abandoned_without_grant`), and is never answered later;
* (d) the requests and tags in use stay within the bounds, and the bridge's
  derived counts agree with what the grant holds (`out_of_bounds`,
  `count_mismatch`);
* (e) a `version` in the session is refused: answered with an error on its
  own tag (`version_served`), while what was in flight before it is still
  answered, as (b) checks.
""".

-export([run/0]).

-define(MSIZE, 8192).
-define(NOFID, 16#ffffffff).
-define(VERSION_TAG, 7).
-define(FLUSHES_PER_REQUEST, 2).
-define(TAGS, [1, 2, 3]).

%% The bridge and what the grant and the host hold:
%% * outstanding: each alias the grant owes a reply at, with what was sent:
%%   a request, or a flush of the request sent to an alias;
%% * sent: the id of the host's request each request alias carries;
%% * abandonable: the ids of requests the grant answered a flush of ok;
%% * host: each tag in use, with the message's id, and for a flush the id of
%%   what it names and of the request its chain ends in;
%% * flushes: the flushes admitted for each request id.
-record(world, {bridge,
                grant :: pid(),
                outstanding = [] :: [{reference(), request | {flush, reference()}}],
                sent = #{} :: #{reference() => pos_integer()},
                abandonable = [] :: [pos_integer()],
                host = #{} :: #{non_neg_integer() => {pos_integer(), request | {flush, pos_integer(), pos_integer()}}},
                flushes = #{} :: #{pos_integer() => pos_integer()},
                next_id = 1 :: pos_integer(),
                budget :: non_neg_integer(),
                version = true :: boolean(),
                down = true :: boolean(),
                limits :: {pos_integer(), pos_integer()},
                trace = [] :: list()}).

%% Requests, tags and host messages of each configuration.
-define(CONFIGURATIONS, [{1, 2, 5}, {2, 2, 5}, {3, 2, 5}, {2, 4, 5}, {3, 6, 5}]).

run() ->
    lists:foreach(fun({Requests, Tags, Budget}) ->
                          #{traces := Traces, steps := Steps} = explore(world(Requests, Tags, Budget), #{traces => 0, steps => 0}),
                          io:format("exhaustive: requests ~b tags ~b budget ~b: ~b traces, ~b steps ok~n",
                                    [Requests, Tags, Budget, Traces, Steps])
                  end, ?CONFIGURATIONS).

%% A session with fid 1 attached to tree a, the one grant's.
world(Requests, Tags, Budget) ->
    Grant = spawn(fun() -> receive stop -> ok end end),
    Trees = fun(<<"a">>) -> {ok, Grant}; (_) -> error end,
    B0 = erx_hostlink_9p:new(#{trees => Trees, alias => fun make_ref/0, requests => Requests, tags => Tags}),
    {B1, _} = erx_hostlink_9p:step({host, erx_9p:encode(100, {version, ?MSIZE, <<"9P2000.L">>}), 0}, B0),
    {B2, Effects} = erx_hostlink_9p:step({host, erx_9p:encode(101, {attach, 1, ?NOFID, <<"u">>, <<"a">>, 0}), 11}, B1),
    [Alias] = [A || {grant, _, A, _} <- Effects],
    {B3, _} = erx_hostlink_9p:step({reply, Alias, {ok, {16#80, 0, 1}}}, B2),
    #world{bridge = B3, grant = Grant, budget = Budget, limits = {Requests, Tags}}.

explore(W, Stats) ->
    quiescent(W),
    case choices(W) of
        [] ->
            Stats#{traces := maps:get(traces, Stats) + 1};
        Choices ->
            lists:foldl(fun(Choice, Acc) ->
                                explore(take(Choice, W), Acc#{steps := maps:get(steps, Acc) + 1})
                        end, Stats, Choices)
    end.

%%% What may happen next

choices(W) ->
    host_choices(W) ++ grant_choices(W).

host_choices(#world{budget = 0}) ->
    [];
host_choices(#world{host = Host, flushes = Flushes, version = Version}) ->
    Free = [Tag || Tag <- ?TAGS, not is_map_key(Tag, Host)],
    New = case Free of
              [Tag | _] ->
                  [{read, Tag} | [{flush, Tag, Old} || Old := Entry <- Host,
                                                       maps:get(root(Entry), Flushes, 0) < ?FLUSHES_PER_REQUEST]];
              [] ->
                  []
          end,
    New ++ [version || Version].

grant_choices(#world{outstanding = Outstanding, down = Down}) ->
    [{reply, Alias, Reply} || {Alias, Kind} <- Outstanding, Reply <- replies(Kind)]
        ++ [grant_down || Down, Outstanding =/= []].

replies(request) -> [{ok, <<"x">>}, junk];
replies({flush, _}) -> [ok, {error, emfile}, junk].

root({Id, request}) -> Id;
root({_Id, {flush, _Target, Root}}) -> Root.

%%% One step

take({read, Tag}, W) ->
    host_message(Tag, {read, 1, 0, 4}, W);
take({flush, Tag, Old}, W) ->
    host_message(Tag, {flush, Old}, W);
take(version, W) ->
    %% A tag of its own, so it is never one a flush names or one in use.
    host_message(?VERSION_TAG, {version, ?MSIZE, <<"9P2000.L">>}, W#world{version = false});
take({reply, Alias, Reply} = Choice, #world{outstanding = Outstanding, sent = Sent, abandonable = Abandonable} = W) ->
    Abandons = case {lists:keyfind(Alias, 1, Outstanding), Reply} of
                   {{Alias, {flush, Target}}, ok} when is_map_key(Target, Sent) -> [map_get(Target, Sent)];
                   _ -> []
               end,
    stepped(Choice, {reply, Alias, Reply}, W#world{outstanding = lists:keydelete(Alias, 1, Outstanding),
                                                   abandonable = Abandons ++ Abandonable});
take(grant_down, #world{grant = Grant} = W) ->
    %% A grant that ended answers nothing more.
    stepped(grant_down, {grant_down, Grant}, W#world{outstanding = [], down = false}).

%% A message the host sends: in use from now on unless the bridge discards it.
host_message(Tag, Request, #world{bridge = B, host = Host, next_id = Id, flushes = Flushes} = W) ->
    Before = maps:get(counts, erx_hostlink_9p:info(B)),
    {Entry, Flushes1} = case Request of
                            {flush, Old} ->
                                Named = maps:get(Old, Host),
                                Root = root(Named),
                                {{Id, {flush, element(1, Named), Root}}, Flushes#{Root => maps:get(Root, Flushes, 0) + 1}};
                            _ ->
                                {{Id, request}, Flushes}
                        end,
    Admitted = W#world{host = Host#{Tag => Entry}, flushes = Flushes1, next_id = Id + 1,
                       budget = W#world.budget - 1},
    W1 = stepped({Tag, Request}, {host, erx_9p:encode(Tag, Request), 0}, Admitted),
    case maps:get(counts, erx_hostlink_9p:info(W1#world.bridge)) of
        Before ->
            W1;
        _Discarded ->
            %% Never admitted: its tag is free, and it is never answered.
            W1#world{host = maps:remove(Tag, W1#world.host),
                     flushes = Flushes, budget = W#world.budget - 1}
    end.

stepped(Choice, Event, #world{bridge = B, trace = Trace} = W) ->
    {B1, Effects} = erx_hostlink_9p:step(Event, B),
    W1 = lists:foldl(fun effect/2, W#world{bridge = B1, trace = [Choice | Trace]}, Effects),
    bounded(W1).

effect({grant, _, Alias, {flush, Target}}, #world{outstanding = Outstanding} = W) ->
    W#world{outstanding = Outstanding ++ [{Alias, {flush, Target}}]};
effect({grant, _, Alias, _Request}, #world{outstanding = Outstanding, sent = Sent, next_id = Next} = W) ->
    %% Only the host's read just taken makes the bridge send a request.
    W#world{outstanding = Outstanding ++ [{Alias, request}], sent = Sent#{Alias => Next - 1}};
effect({unalias, Alias}, #world{outstanding = Outstanding} = W) ->
    %% The runtime drops the reply the grant may still send there.
    W#world{outstanding = lists:keydelete(Alias, 1, Outstanding)};
effect({host, Bytes}, W) ->
    {ok, Tag, {reply, Operation, Reply}} = erx_9p:decode(Bytes, ?MSIZE),
    answer_allowed(Operation, Reply) orelse fail(version_served, {Tag, Reply}, W),
    answered(Tag, W);
effect({monitor, _}, W) ->
    W;
effect({clunk, _, _}, W) ->
    W.

%%% The checks

%% (e): the session is open, so a version's answer is an error.
answer_allowed(version, {error, _}) -> true;
answer_allowed(version, _Served) -> false;
answer_allowed(_Operation, _Reply) -> true.

%% One answer on Tag, as the host takes it: (a) and (c).
answered(Tag, #world{host = Host, abandonable = Abandonable} = W) ->
    case maps:take(Tag, Host) of
        {{Id, {flush, Target, Root}}, Rest} ->
            [fail(flush_before_its_target, Tag, W) || {T, {flush, _, _}} <- maps:values(Rest), T =:= Target],
            [fail(flush_out_of_order, Tag, W) || {Earlier, {flush, _, R}} <- maps:values(Rest), R =:= Root, Earlier < Id],
            %% A request still unanswered was abandoned, by its grant only:
            %% its tag is free.
            [fail(abandoned_without_grant, Tag, W) || {T, request} <- maps:values(Rest), T =:= Target,
                                                      not lists:member(Target, Abandonable)],
            W#world{host = maps:filter(fun(_, {I, _}) -> I =/= Target end, Rest)};
        {_, Rest} ->
            W#world{host = Rest};
        error ->
            fail(tag_not_in_use, Tag, W)
    end.

%% (d): what the grant holds and the tags in use within the bounds, and the
%% bridge's counts the same as what the grant holds.
bounded(#world{bridge = B, outstanding = Outstanding, limits = {RequestsMax, TagsMax}} = W) ->
    Info = erx_hostlink_9p:info(B),
    Requests = length([A || {A, request} <- Outstanding]),
    length(Outstanding) =< TagsMax andalso Requests =< RequestsMax andalso maps:get(tags, Info) =< TagsMax
        orelse fail(out_of_bounds, Info, W),
    maps:get(awaited, Info) =:= length(Outstanding) andalso maps:get(requests, Info) =:= Requests
        orelse fail(count_mismatch, {Info, Outstanding}, W),
    W.

%% (b): a grant that holds nothing leaves nothing the bridge admitted unanswered.
quiescent(#world{outstanding = [], host = Host} = W) when map_size(Host) > 0 ->
    fail(unanswered, Host, W);
quiescent(_W) ->
    ok.

fail(Property, Detail, #world{trace = Trace}) ->
    erlang:error({Property, Detail, lists:reverse(Trace)}).
