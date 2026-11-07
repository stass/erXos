%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_9p).
-moduledoc """
The pure core of the host link's 9P bridge (docs/design-live.md, "Files
between the host and the machine"; docs/design-files.md, "The codec").

The host link's files stream carries one 9P2000.L message in each frame's
body. The bridge decodes each with `erx_9p`, relays it as a term to the
`erx_fs` grant of the tree its fid lies in, and encodes the grant's reply
back to 9P2000.L's bytes. It answers `version`, `auth` and requests it can
refuse itself without asking a grant. `erx_hostlink_files` is the process
that performs what `step/2` returns.

**What the bridge keeps.** For the edge's one 9P session:

* the negotiated `msize`, `none` until a `version` names 9P2000.L;
* a fid table from each fid the host chose to `{Grant, GrantFid}`, the
  grant of its tree and a fid the bridge drew for it on that grant, at most
  the pool's entries, 256, as many as a session's program holds on a grant,
  so the host never spends the fids the grant's other owners need
  (docs/design-files.md, "Bounds"). Fids are the host's to choose, so the
  bridge renames them: it holds every grant fid itself, as their owner, and
  the grants end them all when the bridge ends;
* a tag table from each tag in use to the alias its request or flush was
  sent to, or to `held` for a flush the bridge holds itself, and for each
  alias what is pending there;
* for each tag, the flushes held behind it, answered right after its own
  answer, in the order they came;
* the requests and flushes a `version` forgot that their grants still
  hold, which drain until their replies arrive.

**The fid table follows the requests as they are sent.** A request that
makes a fid (attach, a walk to a new fid, xattrwalk) enters it when the
request is sent, so a host may pipeline a walk and a request on its new
fid, as erXos's grants allow; the reply removes it again when the request
failed, or when a walk stopped short of its last name. A clunk or a remove
takes the fid out when it is sent, since it ends the fid whatever its
outcome. A request names fids of one grant only: one that names fids of two
trees fails with `exdev`, as a rename across file systems does.

**Bounds.** At most 32 requests are pending and 64 tags in use, and what
drains counts against both, so what the bridge has at its grants never
exceeds the 64 requests a grant admits in flight with the flushes waiting
on them, and a grant has room for a flush of every request the bridge sent
it. A request beyond 32 fails with `emfile`, a clunk or remove there still
ends its fid. A message beyond 64 tags, one whose tag is in use, one that
fails the codec and one that is not a request are discarded and counted,
never answered (docs/design-live.md, "Failure handling"). A read's or
readdir's `Count` is cut to what an `Rread` of the negotiated `msize`
holds, and `lopen`'s and `lcreate`'s `Iounit` is answered as `msize` less
24, Linux's and QEMU's `P9_IOHDRSZ`, so every reply fits the stream. A
reply is held to its request with the grammar's reply check before it is
used; one that fails it, or does not encode within `msize`, reaches the host
as `eio`.

**Flush.** A flush of a pending request is sent to that request's grant,
which answers it only after it answered or abandoned the request, and its
`Rflush` goes to the host then. A flush the grant refuses at its bound is
held behind the request. A flush of a flush, sent or held, is held behind
that flush, so its `Rflush` never comes before the one it names and the host
reuses no tag while an answer on it may still come, as flush(5) asks. A
flush of a tag not in use is answered at once.

**Version and ends.** A `version` is served whatever tags are in use, and
resets the session, as 9P2000.L says, unless its `msize` is below 4,096,
which is refused as any request is: every fid is clunked on its grant,
every tag freed and every pending request and flush forgotten, its late
reply never answered. What it forgot drains until its grant replies,
abandons it at a flush, or ends. A grant that ends fails every request
pending on it with `eio`, answers the flushes waiting on them and forgets
its fids and what drains on it.

`step/2` takes one event and returns the next state and the effects, in
order:

* `{host, Bytes}`: send one 9P2000.L message to the host;
* `{grant, Grant, Alias, Request}`: send `Request` to `Grant` as
  `{erx_9p, Alias, Owner, Request}`, the bridge's process the owner;
* `{monitor, Grant}`: watch `Grant` and report its end as `grant_down`;
* `{clunk, Grant, Fid}`: clunk `Fid` on `Grant`, whose answer nobody awaits;
* `{unalias, Alias}`: no reply is awaited at `Alias`: the event brought it
  and it is not used, or its request is forgotten.
""".

-export([new/1, step/2, info/1]).

-export_type([bridge/0, event/0, effect/0, trees/0]).

-include("generated/erx_abi.hrl").

%% The files stream's msize: one frame's body (docs/design-live.md).
-define(MSIZE_MAX, ?ERX_HOSTLINK_BODY_MAX).
%% The smallest msize 9P2000.L's peers accept, as Linux and QEMU refuse less.
-define(MSIZE_MIN, 4096).
-define(VERSION, <<"9P2000.L">>).
-define(UNKNOWN, <<"unknown">>).
%% An Rread's fixed part, size[4] type[1] tag[2] count[4]; an Rreaddir's too.
-define(READ_FIXED, 11).
%% P9_IOHDRSZ, the fixed part Linux and QEMU reserve below msize for any I/O.
-define(IOHDRSZ, 24).
-define(REQUESTS_MAX, 32).
-define(TAGS_MAX, 64).
%% A session's program's fids on a grant (docs/design-files.md, "Bounds").
-define(DEFAULT_POOL, 256).

%% A request or flush sent to a grant: the edge's tag, the grant, the request
%% as the grant received it and as the host sent it.
-record(pending, {tag :: 0..16#ffff,
                  grant :: pid(),
                  request :: tuple(),
                  edge :: tuple()}).

-record(bridge, {trees :: trees(),
                 pool :: pos_integer(),
                 msize = none :: none | ?MSIZE_MIN..?MSIZE_MAX,
                 fids = #{} :: #{non_neg_integer() => {pid(), non_neg_integer()}},
                 tags = #{} :: #{0..16#ffff => reference() | held},
                 pending = #{} :: #{reference() => #pending{}},
                 waiting = #{} :: #{0..16#ffff => [0..16#ffff]},
                 draining = #{} :: #{reference() => #pending{}},
                 %% Pending requests, flushes not counted, draining ones counted.
                 requests = 0 :: non_neg_integer(),
                 grants = #{} :: #{pid() => true},
                 counts = #{} :: #{atom() => pos_integer()}}).

-opaque bridge() :: #bridge{}.
%% The grant of the tree an attach's Aname names, among the trees the host may
%% reach; error for any other name.
-type trees() :: fun((binary()) -> {ok, pid()} | error).
%% A message of the host with a fresh alias and a fid drawn for it, which the
%% request may use; a grant's reply to an alias; a grant's end.
-type event() :: {host, binary(), reference(), non_neg_integer()}
               | {reply, reference(), term()}
               | {grant_down, pid()}.
-type effect() :: {host, binary()}
                | {grant, pid(), reference(), tuple()}
                | {monitor, pid()}
                | {clunk, pid(), non_neg_integer()}
                | {unalias, reference()}.

-doc "A bridge with no session: `trees` finds a tree's grant, `pool` bounds the fid table.".
-spec new(#{trees := trees(), pool => pos_integer()}) -> bridge().
new(#{trees := Trees} = Options) when is_function(Trees, 1) ->
    #bridge{trees = Trees, pool = maps:get(pool, Options, ?DEFAULT_POOL)}.

-doc "Takes one event; returns the next bridge and the effects to perform, in order.".
-spec step(event(), bridge()) -> {bridge(), [effect()]}.
step({host, Bytes, Alias, Drawn}, B) when is_binary(Bytes), is_reference(Alias) ->
    case erx_9p:decode(Bytes, msize(B)) of
        {ok, _Tag, Message} when element(1, Message) =:= reply ->
            discard(not_request, Alias, B);
        {ok, Tag, Request} ->
            admit(Tag, Request, Alias, Drawn, B);
        {error, _Reason} ->
            discard(malformed, Alias, B)
    end;
step({reply, Alias, Reply}, #bridge{pending = Pending} = B) ->
    case maps:take(Alias, Pending) of
        {#pending{request = {flush, _}} = Flush, Rest} ->
            flushed(Flush, Reply, B#bridge{pending = Rest});
        {Request, Rest} ->
            answered(Request, Reply, B#bridge{pending = Rest, requests = B#bridge.requests - 1});
        error ->
            drained(Alias, Reply, B)
    end;
step({grant_down, Grant}, B) ->
    grant_down(Grant, B).

-doc "Counts and sizes, for the inspector and the tests: never a name or a byte of data.".
-spec info(bridge()) -> map().
info(#bridge{msize = Msize, fids = Fids, tags = Tags, draining = Draining, requests = Requests,
             counts = Counts}) ->
    #{msize => Msize, fids => map_size(Fids), tags => map_size(Tags), draining => map_size(Draining),
      requests => Requests, counts => Counts}.

%%% A message of the host

admit(Tag, {version, Msize, Version} = Request, Alias, _Drawn, B) when Msize >= ?MSIZE_MIN ->
    %% A version resets the session, so no tag of it stands in its way.
    version(Tag, Request, Msize, Version, Alias, B);
admit(Tag, _Request, Alias, _Drawn, #bridge{tags = Tags} = B) when is_map_key(Tag, Tags) ->
    discard(tag_in_use, Alias, B);
admit(_Tag, _Request, Alias, _Drawn, #bridge{tags = Tags, draining = Draining} = B)
  when map_size(Tags) + map_size(Draining) >= ?TAGS_MAX ->
    discard(tags_full, Alias, B);
admit(Tag, {version, _, _} = Request, Alias, _Drawn, B) ->
    %% An msize below what 9P2000.L's peers accept: refused, the session kept.
    local(Tag, Request, {error, einval}, Alias, B);
admit(Tag, Request, Alias, _Drawn, #bridge{msize = none} = B) ->
    %% 9P2000.L opens a session with version; nothing else is served before it.
    local(Tag, Request, {error, einval}, Alias, B);
admit(Tag, {auth, _, _, _, _} = Request, Alias, _Drawn, B) ->
    %% The host link's peer is trusted by its transport: auth is not served.
    local(Tag, Request, {error, enotsup}, Alias, B);
admit(Tag, {flush, OldTag} = Request, Alias, _Drawn, B) ->
    flush(Tag, Request, OldTag, Alias, B);
admit(Tag, Request, Alias, Drawn, B) ->
    case route(Request, Drawn, B) of
        {ok, Grant, Renamed} ->
            forward(Tag, Request, Grant, Renamed, Alias, Drawn, B);
        {error, Posix} ->
            local(Tag, Request, {error, Posix}, Alias, B)
    end.

%% A version opens the session afresh: the smaller msize, or unknown for
%% another protocol, which leaves no session.
version(Tag, Request, Msize, Version, Alias, B) ->
    Agreed = min(Msize, ?MSIZE_MAX),
    {B1, Clunks} = reset(B),
    {Session, Answer} = case Version of
                            ?VERSION -> {Agreed, ?VERSION};
                            _ -> {none, ?UNKNOWN}
                        end,
    {B2, Reply} = local(Tag, Request, {ok, Agreed, Answer}, Alias, B1#bridge{msize = Session}),
    {B2, Clunks ++ Reply}.

%% Every fid clunked on its grant, every tag freed, and every pending request
%% and flush forgotten: each drains, its alias open for the reply its grant
%% still owes, and a request still counts among the pending ones.
reset(#bridge{fids = Fids, pending = Pending, draining = Draining} = B) ->
    Clunks = [{clunk, Grant, Fid} || {Grant, Fid} <- maps:values(Fids)],
    {B#bridge{fids = #{}, tags = #{}, pending = #{}, waiting = #{},
              draining = maps:merge(Draining, Pending)},
     Clunks}.

%% A flush of a request pending at a grant goes to that grant. A flush of a
%% flush, sent or held, is held behind it. A flush of a tag not in use is
%% answered at once.
flush(Tag, Request, OldTag, Alias, #bridge{tags = Tags, pending = Pending} = B) ->
    case Tags of
        #{OldTag := OldAlias} ->
            case Pending of
                #{OldAlias := #pending{grant = Grant, request = Old}} when element(1, Old) =/= flush ->
                    Renamed = {flush, OldAlias},
                    Entry = #pending{tag = Tag, grant = Grant, request = Renamed, edge = Request},
                    {B#bridge{tags = Tags#{Tag => Alias}, pending = Pending#{Alias => Entry}},
                     [{grant, Grant, Alias, Renamed}]};
                #{} ->
                    {hold(Tag, OldTag, B), [{unalias, Alias}]}
            end;
        #{} ->
            local(Tag, Request, ok, Alias, B)
    end.

%% The flush Tag held behind OldTag: answered right after OldTag's answer.
hold(Tag, OldTag, #bridge{tags = Tags, waiting = Waiting} = B) ->
    B#bridge{tags = Tags#{Tag => held}, waiting = Waiting#{OldTag => maps:get(OldTag, Waiting, []) ++ [Tag]}}.

%% The grant a request goes to and the request with the grant's fids, or the
%% error the bridge answers itself.
route({attach, Fid, Afid, Uname, Aname, NUname}, Drawn, #bridge{trees = Trees} = B) ->
    case {Afid, new_fid(Fid, B)} of
        {?ERX_P9_NOFID, ok} ->
            case Trees(Aname) of
                {ok, Grant} when is_pid(Grant) ->
                    {ok, Grant, {attach, Drawn, ?ERX_P9_NOFID, Uname, Aname, NUname}};
                _ ->
                    {error, enoent}
            end;
        {?ERX_P9_NOFID, {error, _} = Error} ->
            Error;
        _ ->
            %% auth is not served, so no afid names anything.
            {error, einval}
    end;
route(Request, Drawn, #bridge{fids = Fids} = B) ->
    Named = erx_9p:fids(Request),
    Old = [Fid || {Role, Fid} <- Named, Role =/= new],
    case lists:usort([maps:get(Fid, Fids, missing) || Fid <- Old]) of
        [] ->
            {error, einval};
        Held ->
            case {lists:member(missing, Held), lists:usort([Grant || {Grant, _} <- Held])} of
                {true, _} -> {error, ebadf};
                {false, [_, _ | _]} -> {error, exdev};
                {false, [Grant]} -> renamed(Request, Named, Old, Grant, Drawn, B)
            end
    end.

%% A new fid that is one of the request's own (a walk in place) keeps its
%% grant fid; any other must be free, within the pool, and takes Drawn.
renamed(Request, Named, Old, Grant, Drawn, #bridge{fids = Fids} = B) ->
    New = [Fid || {new, Fid} <- Named, not lists:member(Fid, Old)],
    Admitted = lists:foldl(fun(Fid, ok) -> new_fid(Fid, B);
                              (_, Error) -> Error
                           end, ok, New),
    case Admitted of
        ok ->
            Map = maps:from_list([{Fid, Drawn} || Fid <- New] ++
                                 [{Fid, element(2, map_get(Fid, Fids))} || Fid <- Old]),
            {ok, Grant, erx_9p:map_fids(fun(Fid) -> map_get(Fid, Map) end, Request)};
        {error, _} = Error ->
            Error
    end.

new_fid(Fid, #bridge{fids = Fids, pool = Pool}) ->
    if
        is_map_key(Fid, Fids) -> {error, einval};
        map_size(Fids) >= Pool -> {error, emfile};
        true -> ok
    end.

forward(Tag, Request, Grant, _Renamed, Alias, _Drawn, #bridge{requests = Requests} = B)
  when Requests >= ?REQUESTS_MAX ->
    {B1, Ended} = ended_fid(Request, Grant, B),
    {B2, Reply} = local(Tag, Request, {error, emfile}, Alias, B1),
    {B2, Ended ++ Reply};
forward(Tag, Request, Grant, Renamed, Alias, Drawn,
        #bridge{tags = Tags, pending = Pending, requests = Requests, grants = Grants} = B) ->
    Fids = sent_fids(Request, Grant, Drawn, B#bridge.fids),
    Entry = #pending{tag = Tag, grant = Grant, request = clamped(Renamed, B), edge = Request},
    Watch = case is_map_key(Grant, Grants) of
                true -> [];
                false -> [{monitor, Grant}]
            end,
    {B#bridge{fids = Fids, tags = Tags#{Tag => Alias}, pending = Pending#{Alias => Entry},
              requests = Requests + 1, grants = Grants#{Grant => true}},
     Watch ++ [{grant, Grant, Alias, Entry#pending.request}]}.

%% The fid table once Request is sent: a fid it makes enters, a fid it ends
%% leaves.
sent_fids({Ends, Fid}, _Grant, _Drawn, Fids) when Ends =:= clunk; Ends =:= remove ->
    maps:remove(Fid, Fids);
sent_fids(Request, Grant, Drawn, Fids) ->
    lists:foldl(fun({new, Fid}, Acc) when not is_map_key(Fid, Acc) -> Acc#{Fid => {Grant, Drawn}};
                   (_, Acc) -> Acc
                end, Fids, erx_9p:fids(Request)).

%% A clunk or remove refused at the bound still ends its fid.
ended_fid({Ends, Fid}, Grant, #bridge{fids = Fids} = B) when Ends =:= clunk; Ends =:= remove ->
    {_, GrantFid} = map_get(Fid, Fids),
    {B#bridge{fids = maps:remove(Fid, Fids)}, [{clunk, Grant, GrantFid}]};
ended_fid(_Request, _Grant, B) ->
    {B, []}.

%% A read or readdir asks no more than an Rread of the session's msize holds.
clamped({read, Fid, Offset, Count}, B) ->
    {read, Fid, Offset, min(Count, msize(B) - ?READ_FIXED)};
clamped({readdir, Fid, Offset, Count}, B) ->
    {readdir, Fid, Offset, min(Count, msize(B) - ?READ_FIXED)};
clamped(Request, _B) ->
    Request.

%%% Replies of the grants

answered(#pending{tag = Tag, grant = Grant, request = Renamed, edge = Request}, Reply, B) ->
    {Checked, Stray} = case erx_9p_grammar:decode_reply(Renamed, Reply) of
                           {ok, Held} -> {Held, []};
                           {error, eio} -> {{error, eio}, made_fid_clunk(Request, Renamed, Grant)}
                       end,
    B1 = case made(Request, Checked) of
             true -> B;
             false -> unmade(Request, Renamed, Grant, B)
         end,
    {B2, Answers} = finish(Tag, Request, edge_reply(Request, Checked, B1), B1),
    {B2, Stray ++ Answers}.

%% Whether a request that makes a fid made it: an attach or xattrwalk that
%% succeeded, a walk that walked every name. Any other request makes none.
made({walk, _, _, Names}, {ok, Qids}) -> length(Qids) =:= length(Names);
made({walk, _, _, _}, _) -> false;
made({attach, _, _, _, _, _}, {ok, _}) -> true;
made({attach, _, _, _, _, _}, _) -> false;
made({xattrwalk, _, _, _}, {ok, _}) -> true;
made({xattrwalk, _, _, _}, _) -> false;
made(_, _) -> true.

%% The new fid of a request that did not make it leaves the table, unless a
%% later request already ended or replaced it, or the walk was in place.
unmade(Request, Renamed, Grant, #bridge{fids = Fids} = B) ->
    Pairs = lists:zip(erx_9p:fids(Request), erx_9p:fids(Renamed)),
    Old = [Fid || {{Role, Fid}, _} <- Pairs, Role =/= new],
    Gone = [Fid || {{new, Fid}, {new, GrantFid}} <- Pairs, not lists:member(Fid, Old),
                   maps:get(Fid, Fids, none) =:= {Grant, GrantFid}],
    B#bridge{fids = maps:without(Gone, Fids)}.

%% A reply that failed its check may hide a fid the grant made: it is
%% clunked, and a grant that made none answers that clunk ebadf to nobody.
made_fid_clunk(Request, Renamed, Grant) ->
    Pairs = lists:zip(erx_9p:fids(Request), erx_9p:fids(Renamed)),
    Old = [Fid || {{Role, Fid}, _} <- Pairs, Role =/= new],
    [{clunk, Grant, GrantFid} || {{new, Fid}, {new, GrantFid}} <- Pairs, not lists:member(Fid, Old)].

%% The edge's iounit is what the session's msize carries.
edge_reply({Opens, _, _}, {ok, Qid, _Iounit}, B) when Opens =:= lopen ->
    {ok, Qid, msize(B) - ?IOHDRSZ};
edge_reply({Opens, _, _, _, _, _}, {ok, Qid, _Iounit}, B) when Opens =:= lcreate ->
    {ok, Qid, msize(B) - ?IOHDRSZ};
edge_reply(_Request, Reply, _B) ->
    Reply.

%% A flush answered by its grant, in one of three cases:
%% * ok while its request is pending: the grant abandoned the request, which
%%   is forgotten with no answer of its own, and the flushes held behind it
%%   are answered before this one;
%% * any other reply while its request is pending, a refusal at the grant's
%%   bound or one that fails the grammar: held behind the request;
%% * any reply once the request was answered: answered now.
flushed(#pending{tag = Tag, request = {flush, OldAlias}, edge = Request}, Reply,
        #bridge{pending = Pending} = B) ->
    case {Reply, Pending} of
        {Refused, #{OldAlias := #pending{tag = OldTag}}} when Refused =/= ok ->
            {hold(Tag, OldTag, B), []};
        {ok, #{OldAlias := #pending{tag = OldTag}}} ->
            B1 = B#bridge{pending = maps:remove(OldAlias, Pending), requests = B#bridge.requests - 1},
            {B2, Released} = release(OldTag, B1#bridge{tags = maps:remove(OldTag, B1#bridge.tags)}),
            {B3, Answers} = finish(Tag, Request, ok, B2),
            {B3, [{unalias, OldAlias} | Released] ++ Answers};
        _ ->
            finish(Tag, Request, ok, B)
    end.

%% A reply to what a version forgot: nothing reaches the host. A flush that
%% abandoned its draining request ends that request too, since no reply of
%% its own will come.
drained(Alias, Reply, #bridge{draining = Draining, requests = Requests} = B) ->
    case maps:take(Alias, Draining) of
        {#pending{request = {flush, OldAlias}}, Rest} when Reply =:= ok, is_map_key(OldAlias, Rest) ->
            {B#bridge{draining = maps:remove(OldAlias, Rest), requests = Requests - 1},
             [{unalias, OldAlias}]};
        {#pending{request = {flush, _}}, Rest} ->
            {B#bridge{draining = Rest}, []};
        {#pending{}, Rest} ->
            {B#bridge{draining = Rest, requests = Requests - 1}, []};
        error ->
            {count(stray_reply, B), []}
    end.

%% A grant that ended: its requests fail with eio, then the flushes it held
%% are answered, each followed by the flushes held behind it; its fids and
%% what drains on it are forgotten.
grant_down(Grant, #bridge{pending = Pending, draining = Draining, fids = Fids, grants = Grants} = B) ->
    Mine = [Entry || {_, #pending{grant = G}} = Entry <- maps:to_list(Pending), G =:= Grant],
    {Flushes, Requests} = lists:partition(fun({_, #pending{request = R}}) -> element(1, R) =:= flush end, Mine),
    Drained = [Entry || {_, #pending{grant = G}} = Entry <- maps:to_list(Draining), G =:= Grant],
    DrainedRequests = [A || {A, #pending{request = R}} <- Drained, element(1, R) =/= flush],
    Aliases = [Alias || {Alias, _} <- Mine ++ Drained],
    B1 = B#bridge{pending = maps:without(Aliases, Pending),
                  draining = maps:without(Aliases, Draining),
                  requests = B#bridge.requests - length(Requests) - length(DrainedRequests),
                  fids = maps:filter(fun(_, {G, _}) -> G =/= Grant end, Fids),
                  grants = maps:remove(Grant, Grants)},
    {B2, Failed} = finish_all([{T, R, {error, eio}} || {_, #pending{tag = T, edge = R}} <- Requests], B1),
    {B3, Answered} = finish_all([{T, R, ok} || {_, #pending{tag = T, edge = R}} <- Flushes], B2),
    {B3, [{unalias, Alias} || Alias <- Aliases] ++ Failed ++ Answered}.

%%% Answers to the host

%% Tag's answer, Request's Reply, then the flushes held behind Tag; Tag and
%% theirs are free once answered.
finish(Tag, Request, Reply, #bridge{tags = Tags} = B) ->
    B1 = B#bridge{tags = maps:remove(Tag, Tags)},
    Answer = {host, encoded(Tag, Request, Reply, B1)},
    {B2, Released} = release(Tag, B1),
    {B2, [Answer | Released]}.

finish_all(Answers, B) ->
    lists:foldl(fun({Tag, Request, Reply}, {Acc, Effects}) ->
                        {Acc1, More} = finish(Tag, Request, Reply, Acc),
                        {Acc1, Effects ++ More}
                end, {B, []}, Answers).

%% The flushes held behind Tag, answered ok in the order they came. Each
%% holds at most the flushes behind it, so the depth is within the 64 tags.
release(Tag, #bridge{waiting = Waiting} = B) ->
    case maps:take(Tag, Waiting) of
        {Flushes, Rest} -> finish_all([{Flush, {flush, Tag}, ok} || Flush <- Flushes], B#bridge{waiting = Rest});
        error -> {B, []}
    end.

%%% Helpers

msize(#bridge{msize = none}) -> ?MSIZE_MAX;
msize(#bridge{msize = Msize}) -> Msize.

%% A reply the bridge gives itself, for a message whose alias it does not use.
local(Tag, Request, Reply, Alias, B) ->
    {B, [{unalias, Alias}, {host, encoded(Tag, Request, Reply, B)}]}.

%% Request's reply in 9P2000.L's bytes within the session's msize, or eio
%% when it has no such bytes: a reply of the wrong shape or too large.
encoded(Tag, Request, Reply, B) ->
    Operation = element(1, Request),
    try erx_9p:encode(Tag, {reply, Operation, Reply}, msize(B)) of
        {ok, Bytes} -> Bytes;
        {error, msize} -> erx_9p:encode(Tag, {reply, Operation, {error, eio}})
    catch
        error:badarg -> erx_9p:encode(Tag, {reply, Operation, {error, eio}})
    end.

discard(Why, Alias, B) ->
    {count(Why, B), [{unalias, Alias}]}.

count(Why, #bridge{counts = Counts} = B) ->
    B#bridge{counts = maps:update_with(Why, fun(N) -> N + 1 end, 1, Counts)}.
