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
* one **slot table**, the only record of what is in flight. Each tag the
  host has in use names one slot: a `#request{}` at its grant, or a
  `#flush{}` of a request. Every count and bound is a function of this
  table (`tally/1`); none is kept beside it.

**Flush chains.** The flushes of one request form its chain, in the order
they came, a flush of a flush joining the chain of the request it names.
At most one flush of a chain is at the grant at a time; `settle/1`, which
ends every step, sends the earliest flush still held when none is at the
grant and the request is pending, and answers a chain from its head, in
order, once the request is answered or abandoned and as long as the head
awaits nothing from the grant. So a flush is answered only after its
request and after every earlier flush of it, as flush(5) asks, whatever
the grant does: a flush it refuses or answers malformed waits, and the
next one of the chain goes to the grant; one it answers `ok` while the
request is pending abandons the request, which then gets no answer of its
own. A flush of a tag not in use is answered at once.

**The fid table follows the requests as they are sent.** A request that
makes a fid (attach, a walk to a new fid, xattrwalk) enters it when the
request is sent, so a host may pipeline a walk and a request on its new
fid, as erXos's grants allow; the reply removes it again when the request
failed, was abandoned, or when a walk stopped short of its last name. A
clunk or a remove takes the fid out when it is sent or answered here, since
it ends the fid whatever its outcome. A request names fids of one grant
only: one that names fids of two trees fails with `exdev`, as a rename
across file systems does.

**Bounds.** At most 32 requests are pending and at most 64 tags are in
use, requests and flushes together, so what the bridge has at its grants
never exceeds 64. A request beyond 32 fails with `emfile`; a message that
would take a 65th tag, one whose tag is in use, one that fails the codec
and one that is not a request are discarded and counted, never answered
(docs/design-live.md, "Failure handling"). A read's or readdir's `Count` is cut to what an `Rread` of the
negotiated `msize` holds, and `lopen`'s and `lcreate`'s `Iounit` is
answered as `msize` less 24, Linux's and QEMU's `P9_IOHDRSZ`, so every
reply fits the stream. A reply is held to its request with the grammar's
reply check before it is used; one that fails it, or does not encode within
`msize`, reaches the host as `eio`.

**Version and ends.** A `version` opens the session and is served only
while none is open: one whose `msize` is below 4,096 is refused, one that
names another protocol is answered `unknown` and opens none, and either
leaves the host free to try again. Once a session is open, a `version` is
refused with `einval` as any request the bridge refuses is, and changes
nothing: unlike 9P2000's mid-session reset, the bridge never forgets what
is in flight, since no client it serves sends one and a client starts
afresh by opening a new host-link session (docs/design-live.md). A grant
that ends fails every request pending on it with `eio`; its flushes are
done, so their chains are answered; and its fids are forgotten.

`step/2` takes one event and returns the next state and the effects, in
order:

* `{host, Bytes}`: send one 9P2000.L message to the host;
* `{grant, Grant, Alias, Request}`: send `Request` to `Grant` as
  `{erx_9p, Alias, Owner, Request}`, the bridge's process the owner;
* `{monitor, Grant}`: watch `Grant` and report its end as `grant_down`;
* `{clunk, Grant, Fid}`: clunk `Fid` on `Grant`, whose answer nobody awaits;
* `{unalias, Alias}`: no reply is awaited at `Alias` any more.

The core draws each alias it sends a grant from the `alias` source it was
made with, and makes no other effect itself.
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

-type tag() :: 0..16#ffff.

%% A request at its grant: the alias its reply comes to, the request as the
%% grant received it and as the host sent it.
-record(request, {alias :: reference(),
                  grant :: pid(),
                  sent :: tuple(),
                  edge :: tuple()}).
%% A flush in the chain of the request sent to `target`, at `seq` in the
%% order the bridge took messages: held, never sent; at the grant on an
%% alias; or done, its grant's reply in or its grant ended, waiting only
%% for its turn.
-record(flush, {target :: reference(),
                grant :: pid(),
                seq :: non_neg_integer(),
                at = held :: held | {sent, reference()} | done}).
-type slot() :: #request{} | #flush{}.

-record(bridge, {trees :: trees(),
                 pool :: pos_integer(),
                 alias :: fun(() -> reference()),
                 requests_max :: pos_integer(),
                 tags_max :: pos_integer(),
                 msize = none :: none | ?MSIZE_MIN..?MSIZE_MAX,
                 fids = #{} :: #{non_neg_integer() => {pid(), non_neg_integer()}},
                 slots = #{} :: #{tag() => slot()},
                 %% The next flush's place in its chain: a clock, not a count.
                 seq = 0 :: non_neg_integer(),
                 grants = #{} :: #{pid() => true},
                 counts = #{} :: #{atom() => pos_integer()}}).

-opaque bridge() :: #bridge{}.
%% The grant of the tree an attach's Aname names, among the trees the host may
%% reach; error for any other name.
-type trees() :: fun((binary()) -> {ok, pid()} | error).
%% A message of the host with a fid drawn for it, which the request may use; a
%% grant's reply to an alias; a grant's end.
-type event() :: {host, binary(), non_neg_integer()}
               | {reply, reference(), term()}
               | {grant_down, pid()}.
-type effect() :: {host, binary()}
                | {grant, pid(), reference(), tuple()}
                | {monitor, pid()}
                | {clunk, pid(), non_neg_integer()}
                | {unalias, reference()}.

-doc """
A bridge with no session: `trees` finds a tree's grant, `pool` bounds the fid
table, and `requests` and `tags` set the bounds, 32 and 64, for the tests.
`alias` returns a fresh live alias at each call; a step calls it once for
each message it sends a grant, at most once per request it holds, and the
core owns each alias from then on, until its reply or an `unalias` effect.
""".
-spec new(#{trees := trees(), alias := fun(() -> reference()), pool => pos_integer(),
            requests => pos_integer(), tags => pos_integer()}) -> bridge().
new(#{trees := Trees, alias := Alias} = Options) when is_function(Trees, 1), is_function(Alias, 0) ->
    #bridge{trees = Trees, alias = Alias, pool = maps:get(pool, Options, ?DEFAULT_POOL),
            requests_max = maps:get(requests, Options, ?REQUESTS_MAX),
            tags_max = maps:get(tags, Options, ?TAGS_MAX)}.

-doc "Takes one event; returns the next bridge and the effects to perform, in order.".
-spec step(event(), bridge()) -> {bridge(), [effect()]}.
step({host, Bytes, Drawn}, B) when is_binary(Bytes) ->
    settled(case erx_9p:decode(Bytes, msize(B)) of
                {ok, _Tag, Message} when element(1, Message) =:= reply ->
                    {count(not_request, B), []};
                {ok, Tag, Request} ->
                    admit(Tag, Request, Drawn, B);
                {error, _Reason} ->
                    {count(malformed, B), []}
            end);
step({reply, Alias, Reply}, B) ->
    settled(replied(Alias, Reply, B));
step({grant_down, Grant}, B) ->
    settled(grant_down(Grant, B)).

-doc """
Counts and sizes, for the inspector and the tests, never a name or a byte of
data. Every count of what is in flight is derived from the slot table.
""".
-spec info(bridge()) -> map().
info(#bridge{msize = Msize, fids = Fids, counts = Counts} = B) ->
    (tally(B))#{msize => Msize, fids => map_size(Fids), counts => Counts}.

%%% A message of the host

%% A message is held to its tag, which must be free, and to the tags bound,
%% which a message answered here does not count against.
admit(Tag, _Request, _Drawn, #bridge{slots = Slots} = B) when is_map_key(Tag, Slots) ->
    {count(tag_in_use, B), []};
admit(Tag, Request, Drawn, #bridge{slots = Slots, tags_max = TagsMax} = B) ->
    case plan(Request, Drawn, B) of
        {answer, _} = Plan -> carry_out(Tag, Request, Plan, Drawn, B);
        Plan when map_size(Slots) < TagsMax -> carry_out(Tag, Request, Plan, Drawn, B);
        _Plan -> {count(tags_full, B), []}
    end.

%% What a message asks of the bridge, decided before anything changes:
%% a session opened, answered here, forwarded to a grant, or a flush added
%% to a chain.
plan({version, Msize, Version}, _Drawn, #bridge{msize = none}) when Msize >= ?MSIZE_MIN ->
    %% No session is open, so nothing is in flight: the smaller msize, or
    %% unknown for another protocol, which opens none.
    Agreed = min(Msize, ?MSIZE_MAX),
    case Version of
        ?VERSION -> {open, Agreed, Agreed, ?VERSION};
        _ -> {open, none, Agreed, ?UNKNOWN}
    end;
plan({version, _, _}, _Drawn, _B) ->
    %% An msize below what 9P2000.L's peers accept, or a session already
    %% open: refused, the session as it was.
    {answer, {error, einval}};
plan(_Request, _Drawn, #bridge{msize = none}) ->
    %% 9P2000.L opens a session with version; nothing else is served before it.
    {answer, {error, einval}};
plan({auth, _, _, _, _}, _Drawn, _B) ->
    %% The host link's peer is trusted by its transport: auth is not served.
    {answer, {error, enotsup}};
plan({flush, OldTag}, _Drawn, #bridge{slots = Slots}) ->
    case Slots of
        #{OldTag := #request{alias = Target, grant = Grant}} -> {chain, Target, Grant};
        #{OldTag := #flush{target = Target, grant = Grant}} -> {chain, Target, Grant};
        #{} -> {answer, ok}
    end;
plan(Request, Drawn, #bridge{requests_max = RequestsMax} = B) ->
    case {route(Request, Drawn, B), maps:get(requests, tally(B)) >= RequestsMax} of
        {{ok, _Grant, _Renamed}, true} -> {answer, {error, emfile}};
        {{ok, Grant, Renamed}, false} -> {forward, Grant, clamped(Renamed, B)};
        {{error, Posix}, _} -> {answer, {error, Posix}}
    end.

carry_out(Tag, {version, _, _}, {open, Session, Agreed, Answer}, _Drawn, B) ->
    B1 = B#bridge{msize = Session},
    {B1, [{host, encoded(Tag, version, {ok, Agreed, Answer}, B1)}]};
carry_out(Tag, Request, {answer, Reply}, _Drawn, B) ->
    {B1, Ended} = ended_fid(Request, B),
    {B1, Ended ++ [{host, encoded(Tag, Request, Reply, B1)}]};
carry_out(Tag, Request, {forward, Grant, Sent}, Drawn, B) ->
    forward(Tag, Request, Grant, Sent, Drawn, B);
carry_out(Tag, {flush, _}, {chain, Target, Grant}, _Drawn, #bridge{slots = Slots, seq = Seq} = B) ->
    %% settle/1 sends it or holds it.
    Flush = #flush{target = Target, grant = Grant, seq = Seq},
    {B#bridge{slots = Slots#{Tag => Flush}, seq = Seq + 1}, []}.

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

forward(Tag, Request, Grant, Sent, Drawn, #bridge{slots = Slots, grants = Grants, alias = Fresh} = B) ->
    Alias = Fresh(),
    Watch = case is_map_key(Grant, Grants) of
                true -> [];
                false -> [{monitor, Grant}]
            end,
    Slot = #request{alias = Alias, grant = Grant, sent = Sent, edge = Request},
    {B#bridge{fids = sent_fids(Request, Grant, Drawn, B#bridge.fids), slots = Slots#{Tag => Slot},
              grants = Grants#{Grant => true}},
     Watch ++ [{grant, Grant, Alias, Sent}]}.

%% The fid table once Request is sent: a fid it makes enters, a fid it ends
%% leaves.
sent_fids({Ends, Fid}, _Grant, _Drawn, Fids) when Ends =:= clunk; Ends =:= remove ->
    maps:remove(Fid, Fids);
sent_fids(Request, Grant, Drawn, Fids) ->
    lists:foldl(fun({new, Fid}, Acc) when not is_map_key(Fid, Acc) -> Acc#{Fid => {Grant, Drawn}};
                   (_, Acc) -> Acc
                end, Fids, erx_9p:fids(Request)).

%% A clunk or remove the bridge answers itself, refused at the bound, still
%% ends its fid, as clunk(5) and remove(5) say.
ended_fid({Ends, Fid}, #bridge{fids = Fids} = B) when Ends =:= clunk; Ends =:= remove ->
    case Fids of
        #{Fid := {Grant, GrantFid}} -> {B#bridge{fids = maps:remove(Fid, Fids)}, [{clunk, Grant, GrantFid}]};
        #{} -> {B, []}
    end;
ended_fid(_Request, B) ->
    {B, []}.

%% A read or readdir asks no more than an Rread of the session's msize holds.
clamped({read, Fid, Offset, Count}, B) ->
    {read, Fid, Offset, min(Count, msize(B) - ?READ_FIXED)};
clamped({readdir, Fid, Offset, Count}, B) ->
    {readdir, Fid, Offset, min(Count, msize(B) - ?READ_FIXED)};
clamped(Request, _B) ->
    Request.

%%% Replies of the grants

%% The one slot that awaits a reply at Alias, or a stray reply.
replied(Alias, Reply, #bridge{slots = Slots} = B) ->
    case [{Tag, Slot} || Tag := Slot <- Slots, awaits(Slot) =:= Alias] of
        [{Tag, #request{} = Request}] -> answered(Tag, Request, Reply, B);
        [{Tag, #flush{} = Flush}] -> flush_replied(Tag, Flush, Reply, B);
        [] -> {count(stray_reply, B), []}
    end.

%% The alias a slot awaits a grant's reply at, or none.
awaits(#request{alias = Alias}) -> Alias;
awaits(#flush{at = {sent, Alias}}) -> Alias;
awaits(#flush{}) -> none.

answered(Tag, #request{grant = Grant, sent = Sent, edge = Request}, Reply, #bridge{slots = Slots} = B) ->
    B1 = B#bridge{slots = maps:remove(Tag, Slots)},
    {Checked, Clunks} = case erx_9p_grammar:decode_reply(Sent, Reply) of
                           {ok, Held} -> {Held, []};
                           {error, eio} -> {{error, eio}, made_fid_clunk(Request, Sent, Grant)}
                       end,
    B2 = case made(Request, Checked) of
             true -> B1;
             false -> unmade(Request, Sent, Grant, B1)
         end,
    {B2, Clunks ++ [{host, encoded(Tag, Request, edge_reply(Request, Checked, B2), B2)}]}.

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
unmade(Request, Sent, Grant, #bridge{fids = Fids} = B) ->
    Pairs = lists:zip(erx_9p:fids(Request), erx_9p:fids(Sent)),
    Old = [Fid || {{Role, Fid}, _} <- Pairs, Role =/= new],
    Gone = [Fid || {{new, Fid}, {new, GrantFid}} <- Pairs, not lists:member(Fid, Old),
                   maps:get(Fid, Fids, none) =:= {Grant, GrantFid}],
    B#bridge{fids = maps:without(Gone, Fids)}.

%% A request whose outcome the bridge does not know, a reply that failed its
%% check or one abandoned at a flush, may have made a fid at its grant: it is
%% clunked, and a grant that made none answers that clunk ebadf to nobody.
made_fid_clunk(Request, Sent, Grant) ->
    Pairs = lists:zip(erx_9p:fids(Request), erx_9p:fids(Sent)),
    Old = [Fid || {{Role, Fid}, _} <- Pairs, Role =/= new],
    [{clunk, Grant, GrantFid} || {{new, Fid}, {new, GrantFid}} <- Pairs, not lists:member(Fid, Old)].

%% The edge's iounit is what the session's msize carries.
edge_reply({lopen, _, _}, {ok, Qid, _Iounit}, B) ->
    {ok, Qid, msize(B) - ?IOHDRSZ};
edge_reply({lcreate, _, _, _, _, _}, {ok, Qid, _Iounit}, B) ->
    {ok, Qid, msize(B) - ?IOHDRSZ};
edge_reply(_Request, Reply, _B) ->
    Reply.

%% A flush's reply is in, so it awaits nothing more. An ok while its request
%% is pending means the grant abandoned the request, which then ends with no
%% answer of its own; any other reply, a refusal or one malformed, leaves the
%% request pending. settle/1 answers the chain or sends its next flush.
flush_replied(Tag, #flush{target = Target} = Flush, Reply, #bridge{slots = Slots} = B) ->
    B1 = B#bridge{slots = Slots#{Tag := Flush#flush{at = done}}},
    case {Reply, pending_request(Target, Slots)} of
        {ok, {OldTag, Request}} -> abandoned(OldTag, Request, B1);
        _ -> {B1, []}
    end.

abandoned(OldTag, #request{alias = Alias, grant = Grant, sent = Sent, edge = Request}, #bridge{slots = Slots} = B) ->
    B1 = unmade(Request, Sent, Grant, B#bridge{slots = maps:remove(OldTag, Slots)}),
    {B1, [{unalias, Alias} | made_fid_clunk(Request, Sent, Grant)]}.

%% A grant that ended: its pending requests fail with eio, its flushes are
%% done, and its fids are gone. settle/1 then answers the chains of those
%% requests.
grant_down(Grant, #bridge{slots = Slots, fids = Fids, grants = Grants} = B) ->
    Mine = lists:sort([{Tag, Slot} || Tag := Slot <- Slots, grant_of(Slot) =:= Grant]),
    Awaited = [awaits(Slot) || {_Tag, Slot} <- Mine],
    B1 = B#bridge{slots = lists:foldl(fun ended/2, Slots, Mine),
                  fids = maps:filter(fun(_, {G, _}) -> G =/= Grant end, Fids),
                  grants = maps:remove(Grant, Grants)},
    Failed = [{host, encoded(Tag, Request, {error, eio}, B1)} || {Tag, #request{edge = Request}} <- Mine],
    {B1, [{unalias, Alias} || Alias <- Awaited, Alias =/= none] ++ Failed}.

%% A slot of a grant that ended: a flush stays in its chain, done; a request
%% goes.
ended({Tag, #flush{} = Flush}, Slots) -> Slots#{Tag := Flush#flush{at = done}};
ended({Tag, #request{}}, Slots) -> maps:remove(Tag, Slots).

grant_of(#request{grant = Grant}) -> Grant;
grant_of(#flush{grant = Grant}) -> Grant.

%%% Flush chains

%% Every step ends here, so after each one every chain is settled: a chain
%% whose request is pending has a flush at the grant if it has one to send,
%% and a chain whose request is answered or abandoned has been answered from
%% its head up to the first flush that still awaits the grant.
settled({B, Effects}) ->
    {B1, More} = settle(B),
    {B1, Effects ++ More}.

settle(#bridge{slots = Slots} = B) ->
    Targets = lists:usort([Target || _ := #flush{target = Target} <- Slots]),
    lists:foldl(fun(Target, {Acc, Effects}) ->
                        {Acc1, More} = settle_chain(pending_request(Target, Acc#bridge.slots), chain(Target, Acc), Acc),
                        {Acc1, Effects ++ More}
                end, {B, []}, Targets).

settle_chain({_Tag, #request{}}, Chain, B) ->
    case {at_grant(Chain), [F || {_, #flush{at = held}} = F <- Chain]} of
        {[], [{Tag, Flush} | _]} -> send_flush(Tag, Flush, B);
        {_, _} -> {B, []}
    end;
settle_chain(none, Chain, B) ->
    answer_head(Chain, B).

send_flush(Tag, #flush{target = Target, grant = Grant} = Flush, #bridge{slots = Slots, alias = Fresh} = B) ->
    Alias = Fresh(),
    {B#bridge{slots = Slots#{Tag := Flush#flush{at = {sent, Alias}}}}, [{grant, Grant, Alias, {flush, Target}}]}.

%% The chain's flushes answered in order while the head awaits nothing from
%% the grant: a flush still at the grant stops the chain until its reply.
answer_head([{_Tag, #flush{at = {sent, _}}} | _], B) ->
    {B, []};
answer_head([{Tag, #flush{}} | Rest], #bridge{slots = Slots} = B) ->
    B1 = B#bridge{slots = maps:remove(Tag, Slots)},
    {B2, More} = answer_head(Rest, B1),
    {B2, [{host, encoded(Tag, flush, ok, B1)} | More]};
answer_head([], B) ->
    {B, []}.

%% The flushes of a chain at the grant: none or one.
at_grant(Chain) ->
    [F || {_, #flush{at = {sent, _}}} = F <- Chain].

%% The flushes of the request sent to Target, in the order they came.
chain(Target, #bridge{slots = Slots}) ->
    [{Tag, Flush} || {_, Tag, Flush} <- lists:sort([{Seq, Tag, F} || Tag := #flush{target = T, seq = Seq} = F <- Slots,
                                                                  T =:= Target])].

%% The request still pending at alias Target, or none once it was answered,
%% abandoned or failed.
pending_request(Target, Slots) ->
    case [{Tag, R} || Tag := #request{alias = Alias} = R <- Slots, Alias =:= Target] of
        [Pending] -> Pending;
        [] -> none
    end.

%%% Counts, all derived from the slot table

%% Tags in use, requests and flushes at a grant or held, and the replies the
%% grants owe.
tally(#bridge{slots = Slots}) ->
    maps:fold(fun(_Tag, Slot, Acc) -> tallied(Slot, Acc) end,
              #{tags => map_size(Slots), requests => 0, flushes => 0, awaited => 0}, Slots).

tallied(Slot, Acc) ->
    Counted = bump(kind_count(Slot), Acc),
    case awaits(Slot) of
        none -> Counted;
        _Alias -> bump(awaited, Counted)
    end.

bump(Count, Counts) ->
    maps:update_with(Count, fun(N) -> N + 1 end, Counts).

kind_count(#request{}) -> requests;
kind_count(#flush{}) -> flushes.

%%% Helpers

msize(#bridge{msize = none}) -> ?MSIZE_MAX;
msize(#bridge{msize = Msize}) -> Msize.

%% Request's reply, or Operation's, in 9P2000.L's bytes within the session's
%% msize, or eio when it has no such bytes: a reply of the wrong shape or too
%% large.
encoded(Tag, Request, Reply, B) when is_tuple(Request) ->
    encoded(Tag, element(1, Request), Reply, B);
encoded(Tag, Operation, Reply, B) ->
    try erx_9p:encode(Tag, {reply, Operation, Reply}, msize(B)) of
        {ok, Bytes} -> Bytes;
        {error, msize} -> erx_9p:encode(Tag, {reply, Operation, {error, eio}})
    catch
        error:badarg -> erx_9p:encode(Tag, {reply, Operation, {error, eio}})
    end.

count(Why, #bridge{counts = Counts} = B) ->
    B#bridge{counts = maps:update_with(Why, fun(N) -> N + 1 end, 1, Counts)}.
