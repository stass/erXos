%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_grant).
-moduledoc """
The pure core of one `erx_fs` grant (docs/design-files.md#serving-the-erx_fs-behaviour).

A grant serves one client domain's requests on one tree. This module holds
everything the grant knows, its fid table, the owners it monitors and the
requests it has in flight, and decides each step: `handle_frame/2` takes one
message the grant received and returns the effects to perform, in order, and
the next state. `erx_fs`, the process shell, performs them:

* `{reply, Alias, Reply}`: send `{erx_9p, Alias, Reply}` to `Alias`;
* `{monitor, Owner}`: monitor `Owner` and hand the reference back with
  `monitored/3` before the next step;
* `{demonitor, Ref}`: `erlang:demonitor(Ref, [flush])`;
* `{wait, Alias, Keeper, Request}`: monitor `Keeper` with an alias that its
  first reply deactivates, send it the request (erx_fs_waits.hrl), and hand
  the alias back with `waiting/3` before the next step;
* `{flush, Keeper, KeeperAlias}`: send `Keeper` the flush of the request it
  holds under that alias.

The core calls the tree's callback module itself, for every request, one at
a time, in the order the requests arrive; a walk asks the tree one name at a
time and each answer decides the next question. A read or a write that must
wait for an event answers `{wait, Keeper, Request}`, and the request goes to
its keeper, which answers it later through `answered/3`, or ends and is
seen through `down/3`, while the grant goes on with its client's other
requests. The core reads no other state and sends nothing. Every callback
receives `Fs` as `init/1` answered it: a tree's handle, which never changes
and to which a callback answers only its result, or a tree of the grant's
own, which a callback answers anew with its result and which tree/3,4
threads through the grant; an answer that
is none of its callback's shapes reaches the client as `eio`, through
`failed/1` or the grammar's reply check in `finish/5`, and a keeper's answer
is held to the same shapes and the same check.

Every frame passes one funnel, `decode/2`, which takes the grant's rights:
dispatch receives only requests the funnel admitted, so a writing request on a
read-only grant never reaches a callback (F5).

The fid table and `closing` are the one record of which fids are alive: a fid
whose clunk waits for its held requests is in `closing`, where no request
reaches it but its number stays taken. Each fid has an owner,
fixed for its life; `owners` maps each owner of a live fid to its monitor and
its set of fids, and holds no other process, so the grant never monitors more
processes than it holds fids (F10, design-files.md#fid-owners). An opened
fid keeps the handle its open answered; `close_fid/3`, the one place a fid
ends, runs the tree's `clunk` of that handle.

A fid names at most two nodes: the node it was walked to and the directory
of the entry it was walked by (place/0), so what the grant keeps for a fid
is the same at any depth; no walk names `..`, which the grammar refuses, so
the grant keeps no chain of directories back to its root. A fid's name is
copied as it enters the fid, so it pins no larger binary it was carved
from. A tree that offers `forget/2` holds each node its `walk/3` answers
for the grant until the grant forgets it. `held` records those nodes, and
`named` counts, per node, the fids that name it, which only `recount/3`
changes. A node a walk answered, and one a fid stopped naming, is `loose`
until the step ends: `drain/1`, which every step ends through, forgets
each loose node that is held and named by no fid. So after every step the
grant holds exactly the walked nodes its fids name, whichever way the step
went: a walk that stopped, a reply the check rejected, a clunk, an owner's
end.
""".

-export([new/1, tree/1, rights/1, handle_frame/2, monitored/3, waiting/3, answered/3, down/3, client_ended/1,
         drained/1, info/1, in_flight_max/0, fid_words/2]).

-export_type([grant/0, effect/0, rights/0, client/0]).

-include("generated/erx_abi.hrl").

-define(MSIZE_MIN, 4096).
-define(MSIZE_MAX, 65560).
-define(VERSION, <<"9P2000.L">>).
-define(IN_FLIGHT_MAX, 64).
-define(DEFAULT_POOL, 4096).
%% An open's iounit: 0 has the client size its reads and writes by msize.
-define(IOUNIT, 0).
%% The most entries one readdir callback is asked for.
-define(DIRENTS_PER_CALL, 256).

-type rights() :: erx_abi_enums:files_rights().
%% The domain a grant serves: the server's own, or another by its domain id.
-type client() :: own | pos_integer().
-type fid() :: 0..16#fffffffe.
-type qid() :: {0..255, 0..16#ffffffff, 0..16#ffffffffffffffff}.

%% What a fid denotes: the node it was walked to, with its qid, and the entry
%% it was walked by, the directory it was walked from and its name there, or
%% root for the grant's root. Node operations use the node, whatever it is
%% named now; remove uses the entry, with the node as its check.
-type entry() :: root | {Dir :: term(), Name :: binary()}.
-type place() :: {Node :: term(), qid(), entry()}.

%% A fid is unopened, or open with the tree's Handle on the node of its
%% place. An open fid's place never changes, since no walk starts from it.
-record(fid, {owner :: pid(),
              at :: place(),
              open = none :: none | {open, Handle :: term()}}).

%% An owner's monitor is `pending` from the step that made its first fid until
%% the shell hands its reference back with monitored/3.
-record(owner, {monitor :: reference() | pending,
                fids :: #{fid() => []}}).

%% A read or a write a keeper holds: its fid, the request, and the keeper with
%% the keeper alias, the alias of the grant's monitor of the keeper, `unsent`
%% from the step that handed the request over until the shell hands the alias
%% back with waiting/3. `flushed` once the keeper has been sent the request's
%% flush, by the client's flush or by its fid's clunk, so it is sent it once.
-record(held, {fid :: fid(), request :: tuple(), keeper :: pid(),
               at = unsent :: reference() | unsent, flushed = false :: boolean()}).

%% A live alias (design-files.md, "Pipelined requests"): one the grant has
%% still to answer, or, for a keeper alias, still to hear from. `what` is
%%
%% * a #held{}: the client's read or write a keeper holds;
%% * {flush, Old}: a flush of the live alias Old, a held request or a held
%%   clunk or remove, answered after Old is;
%% * ending: a clunk or a remove, answered once the requests of its fid that
%%   keepers hold are answered and its clunk has run (rule 5); its #closing{}
%%   holds the rest;
%% * {keeper, Alias}: a keeper alias, naming the client's Alias of the request
%%   the keeper holds, whose answer comes to it.
%%
%% `flush` is the one flush of the client's waiting on the alias. A frame sent
%% to a live alias is dropped and counted, and so is a second flush of one. A
%% flush of a flush is answered at once and never live, so no flush waits on
%% another.
-record(live, {what :: #held{} | {flush, reference()} | ending | {keeper, reference()},
               flush = none :: reference() | none}).

%% A fid whose clunk or remove waits for the requests of it that keepers hold:
%% the fid, the ending request and its client's alias, none for a clunk the
%% grant makes itself, the answer it gets once its clunk has run, and how many
%% of the fid's requests keepers still hold. The answer is `closed` for what
%% the tree's clunk answers; a remove's was decided when it was taken, by its
%% unlink or its refusal.
-record(closing, {fid :: #fid{}, alias :: reference() | none,
                  request :: {clunk | remove, fid()}, answer :: closed | term(),
                  waits :: non_neg_integer()}).

-record(grant, {module :: module(),
                %% init's answer: {ok, Fs}, a handle to a tree kept elsewhere, or
                %% {own, Tree}, the tree itself, which tree/4 alone passes to the
                %% callbacks and replaces with their next tree.
                fs :: {ok, term()} | {own, term()},
                %% The tree the grant reaches files of and the step a walk from NOFID
                %% starts at, the root the start admitted (new/1).
                tree :: binary(),
                root :: place(),
                rights :: rights(),
                client :: client(),
                self :: pid(),
                pool :: pos_integer(),
                in_flight_max :: 1..?IN_FLIGHT_MAX,
                msize_max :: ?MSIZE_MIN..?MSIZE_MAX,
                fids = #{} :: #{fid() => #fid{}},
                closing = #{} :: #{fid() => #closing{}},
                owners = #{} :: #{pid() => #owner{}},
                named = #{} :: #{term() => pos_integer()},
                held = #{} :: #{term() => []},
                loose = [] :: [term()],
                aliases = #{} :: #{reference() => #live{}},
                %% The requests' window: the live aliases window/1 counts.
                in_flight = 0 :: non_neg_integer(),
                refused = 0 :: non_neg_integer(),
                %% Once the client has ended, the grant drains and answers nothing.
                ended = false :: boolean(),
                effects = [] :: [effect()]}).

-opaque grant() :: #grant{}.
-type effect() :: {reply, reference(), term()}
                | {monitor, pid()}
                | {demonitor, reference()}
                | {wait, Alias :: reference(), Keeper :: pid(), Request :: term()}
                | {flush, Keeper :: pid(), KeeperAlias :: reference()}.
-type call() :: {read, Handle :: term(), non_neg_integer(), pos_integer()}
              | {write, Handle :: term(), non_neg_integer(), binary()}
              | {readdir, Handle :: term(), non_neg_integer(), pos_integer()}
              | {fsync, Handle :: term()}
              | {setattr, Handle :: term(), map()}.

-doc """
A grant with no fids, served by the calling process. `rights` is the grant's
(`ro`, `rw` or `rx`); a tree whose module has no `write/4` callback is
read-only whatever they say (F5). `client` is the domain the grant serves,
`own` for the server's own domain or another domain's id, `pool` its fid
bound, `in_flight` the most requests it holds at once (64 at most, and the
default) and `msize` the largest message size it agrees to (4,096 to 65,560,
the default).

The grant asks the tree's `root` once, before it takes any request, and
admits the answer by one check: the tree a plain name of 1 to 255 bytes and
the qid the grammar's, a directory's. An answer that fails it is
`{error, root}`, so no grant exists whose root is unchecked. The grant then
fixes the tree's name and the root's node and qid for its life: a walk from
`NOFID` starts there, and an `attach` there once the tree's fresh answer
names the same tree, type and path (docs/design-files.md, "The root is
admitted when the grant is made").
""".
-spec new(#{module := module(), fs := {ok, term()} | {own, term()}, rights := rights(),
            client := client(), pool => pos_integer(),
            in_flight => 1..?IN_FLIGHT_MAX, msize => ?MSIZE_MIN..?MSIZE_MAX}) ->
          {ok, grant()} | {error, root}.
new(#{module := Module, fs := Fs, rights := Rights, client := Client} = Options)
  when ?ERX_IS_FILES_RIGHTS(Rights),
       Client =:= own orelse is_integer(Client) andalso Client > 0 ->
    Pool = maps:get(pool, Options, ?DEFAULT_POOL),
    true = is_integer(Pool) andalso Pool > 0,
    InFlightMax = maps:get(in_flight, Options, ?IN_FLIGHT_MAX),
    true = is_integer(InFlightMax) andalso InFlightMax >= 1 andalso InFlightMax =< ?IN_FLIGHT_MAX,
    MsizeMax = maps:get(msize, Options, ?MSIZE_MAX),
    true = is_integer(MsizeMax) andalso MsizeMax >= ?MSIZE_MIN andalso MsizeMax =< ?MSIZE_MAX,
    Writes = erlang:function_exported(Module, write, 4),
    Grant = #grant{module = Module, fs = Fs, client = Client, self = self(), pool = Pool,
                   in_flight_max = InFlightMax, msize_max = MsizeMax,
                   rights = effective_rights(Rights, Writes)},
    {Answer, Grant1} = tree(root, [], Grant),
    case admitted_root(Answer) of
        {ok, Tree, Root} -> {ok, Grant1#grant{tree = Tree, root = Root}};
        error -> {error, root}
    end.

effective_rights(rw, false) -> ro;
effective_rights(Rights, _) -> Rights.

%% The root's one check: a tree that is a plain name, and a qid of the grammar's
%% qid kind whose type is a directory, as the place every walk from NOFID starts at.
admitted_root({ok, Tree, Node, {Type, _, _} = Qid}) ->
    case erx_9p_grammar:is_name(Tree) andalso erx_9p_grammar:is_qid(Qid)
        andalso Type band ?ERX_P9_QTDIR =/= 0 of
        true -> {ok, Tree, {Node, Qid, root}};
        false -> error
    end;
admitted_root(_) ->
    error.

-doc "The tree the grant reaches files of, as its start admitted it.".
-spec tree(grant()) -> binary().
tree(#grant{tree = Tree}) -> Tree.

-doc "The rights the grant serves: those it was made with, `ro` for `rw` on a tree that writes nothing.".
-spec rights(grant()) -> rights().
rights(#grant{rights = Rights}) -> Rights.

-doc "One message the grant received, other than a `DOWN` or a keeper's answer.".
-spec handle_frame(term(), grant()) -> {[effect()], grant()}.
handle_frame(Frame, #grant{aliases = Live} = Grant) ->
    case decode(Frame, Grant) of
        drop ->
            dropped(Grant);
        {_, Alias, _, _} when is_map_key(Alias, Live) ->
            dropped(Grant);
        {refuse, Alias, Posix, {Ends, Fid} = Request} when Ends =:= clunk; Ends =:= remove ->
            end_fid(Alias, Fid, Request, {error, Posix}, Grant);
        {refuse, Alias, Posix, Request} ->
            finish(Alias, Request, {error, Posix}, Grant);
        {admit, Alias, Owner, Request} ->
            admit(Alias, Owner, Request, Grant)
    end.

%% A frame the grant takes nothing from: one it may not answer, one sent to a
%% live alias, which an answer would reach as its earlier request's, and a
%% second flush of one live alias.
dropped(Grant) ->
    drain(count_refusal(Grant)).

-doc "The reference of the monitor the shell made for an `{monitor, Owner}` effect.".
-spec monitored(pid(), reference(), grant()) -> grant().
monitored(Owner, Ref, #grant{owners = Owners} = Grant) ->
    #{Owner := #owner{monitor = pending} = Record} = Owners,
    Grant#grant{owners = Owners#{Owner := Record#owner{monitor = Ref}}}.

-doc """
The keeper alias the shell made for a `{wait, ClientAlias, Keeper, Request}`
effect: the alias of its monitor of `Keeper`, which it sent the request with.
""".
-spec waiting(reference(), reference(), grant()) -> grant().
waiting(ClientAlias, KeeperAlias, #grant{aliases = Live} = Grant) ->
    #{ClientAlias := #live{what = #held{at = unsent} = Held} = Entry} = Live,
    Sent = Live#{ClientAlias := Entry#live{what = Held#held{at = KeeperAlias}}},
    live(KeeperAlias, {keeper, ClientAlias}, Grant#grant{aliases = Sent}).

-doc """
A keeper's answer to the request it holds under `KeeperAlias`, held to the
shapes of the request's callback and to the grammar's reply check as an
answer made at once is. An answer to no alias the grant waits on answers
nothing and is counted as refused, as any other message the grant cannot take.
""".
-spec answered(reference(), term(), grant()) -> {[effect()], grant()}.
answered(KeeperAlias, Result, #grant{aliases = Live} = Grant) ->
    case Live of
        #{KeeperAlias := #live{what = {keeper, ClientAlias}}} ->
            #{ClientAlias := #live{what = #held{request = Request}}} = Live,
            settle_held(KeeperAlias, ClientAlias, shaped(element(1, Request), Result), Grant);
        #{} ->
            dropped(Grant)
    end.

-doc """
A `DOWN`: a keeper's end answers the request it held `eio`, since what was
done for it is not known; an owner's clunks every fid it still owns, as if it
had sent the clunks, with no one to answer. A `DOWN` of no monitor the grant
holds changes nothing.
""".
-spec down(reference(), pid(), grant()) -> {[effect()], grant()}.
down(Ref, Pid, #grant{aliases = Live, owners = Owners} = Grant) ->
    case {Live, Owners} of
        {#{Ref := #live{what = {keeper, ClientAlias}}}, _} ->
            settle_held(Ref, ClientAlias, {error, eio}, Grant);
        {_, #{Pid := #owner{monitor = Ref}}} ->
            owner_down(Pid, Grant);
        _ ->
            {[], Grant}
    end.

%% An owner's end: the grant forgets the owner, whose monitor has fired, and
%% clunks each fid it owns by rule 5; one already closing has its clunk on the
%% way, whose end then finds no owner to update.
owner_down(Owner, #grant{owners = Owners, effects = Effects} = Grant) ->
    {#owner{monitor = Ref, fids = Owned}, Rest} = maps:take(Owner, Owners),
    Forgotten = drain(Grant#grant{owners = Rest, effects = [{demonitor, Ref} | Effects]}),
    lists:foldl(fun(Fid, Step) -> then(Step, fun(G) -> end_owned(Fid, G) end) end,
                Forgotten, maps:keys(Owned)).

end_owned(Fid, #grant{fids = Fids} = Grant) when is_map_key(Fid, Fids) ->
    end_fid(none, Fid, {clunk, Fid}, closed, Grant);
end_owned(_, Grant) ->
    {[], Grant}.

-doc """
The client's end: the grant drains (design-files.md, "What waiting holds").
It answers nothing from then on and clunks every fid by rule 5, as an
owner's end does; the shell takes no frame after this and ends once
`drained/1` holds.
""".
-spec client_ended(grant()) -> {[effect()], grant()}.
client_ended(#grant{fids = Fids} = Grant) ->
    lists:foldl(fun(Fid, Step) -> then(Step, fun(G) -> end_owned(Fid, G) end) end,
                drain(Grant#grant{ended = true}), maps:keys(Fids)).

-doc "Whether every fid has ended and its clunk has run.".
-spec drained(grant()) -> boolean().
drained(#grant{fids = Fids, closing = Closing}) ->
    map_size(Fids) + map_size(Closing) =:= 0.

%% The effects of a step, then those of Next on the grant the step left.
then({Effects, Grant}, Next) ->
    {More, Grant1} = Next(Grant),
    {Effects ++ More, Grant1}.

%% A request on an open file, its answer or, for a read or a write, a wait,
%% with the grant its callback left.
-spec call(call(), grant()) -> {term(), grant()}.
call({read, Handle, Offset, Count}, Grant) ->
    answered_by(fun(A) -> may_wait(read, A) end, tree(read, [Handle, Offset, Count], Grant));
call({write, Handle, Offset, Data}, Grant) ->
    answered_by(fun(A) -> may_wait(write, A) end, tree(write, [Handle, Offset, Data], Grant));
call({readdir, Handle, Offset, Count}, Grant) ->
    case Count div packed_entry(<<>>) of
        0 ->
            {{error, einval}, Grant};
        Fit ->
            answered_by(fun({ok, Entries}) -> fit_listing(Entries, Count);
                           (Other) -> failed(Other)
                        end,
                        tree(readdir, [Handle, Offset, min(Fit, ?DIRENTS_PER_CALL)], Grant))
    end;
call({fsync, Handle}, Grant) ->
    answered_by(fun done/1, tree(fsync, [Handle], ok, Grant));
call({setattr, Handle, Attr}, Grant) ->
    answered_by(fun done/1, tree(setattr, [{open, Handle}, Attr], {error, eperm}, Grant)).

%% A callback's answer as Shape holds it to its callback's shapes, beside the grant.
answered_by(Shape, {Answer, Grant}) ->
    {Shape(Answer), Grant}.

%% A read or a write waits when its callback answers so; its answer, now or
%% from its keeper, is one of the callback's shapes or failed.
may_wait(_, {wait, Keeper, Request}) -> {wait, Keeper, Request};
may_wait(Operation, Answer) -> shaped(Operation, Answer).

shaped(read, {ok, Data}) -> {ok, Data};
shaped(write, {ok, Count, At}) -> {ok, Count, At};
shaped(_, Other) -> failed(Other).

%% The answer of a callback that answers ok or an error.
done(ok) -> ok;
done(Other) -> failed(Other).

%% A callback's error, or eio for an answer that is none of its callback's
%% shapes, so a malformed answer reaches the client and leaves the grant as
%% it was.
failed({error, Posix}) when is_atom(Posix) -> {error, Posix};
failed(_) -> {error, eio}.

%% A listing keeps the entries that fit the request's count, as the wire packs
%% them; a first entry that does not fit is einval, as getdents answers a
%% buffer too small for one entry. The entries left out are read again from
%% the last kept entry's offset. A listing that is not a list of entries
%% passes unchanged, so the grammar's reply check answers it eio; the check
%% also holds every kept entry to the grammar.
fit_listing([], _) ->
    {ok, []};
fit_listing(Entries, Count) ->
    case entries(Entries) of
        true ->
            case take_fitting(Entries, Count, []) of
                [] -> {error, einval};
                Kept -> {ok, Kept}
            end;
        false ->
            {ok, Entries}
    end.

%% A proper list of entries; an improper one is malformed too.
entries([]) -> true;
entries([{_, _, _, Name} | Entries]) when is_binary(Name) -> entries(Entries);
entries(_) -> false.

take_fitting([{_, _, _, Name} = Entry | Entries], Room, Kept) ->
    case Room - packed_entry(Name) of
        Left when Left >= 0 -> take_fitting(Entries, Left, [Entry | Kept]);
        _ -> lists:reverse(Kept)
    end;
take_fitting([], _, Kept) ->
    lists:reverse(Kept).

packed_entry(Name) ->
    erx_9p_grammar:packed_dirents([{{0, 0, 0}, 0, 0, Name}]).

-doc """
What the grant holds, for inspection and tests: its fids, closing ones
included, their owners, the requests keepers hold, the requests' window,
every live alias, the frames it refused or dropped, and its rights.
""".
-spec info(grant()) -> #{fids := non_neg_integer(), owners := non_neg_integer(),
                         waiting := non_neg_integer(), in_flight := non_neg_integer(),
                         aliases := non_neg_integer(), refused := non_neg_integer(),
                         rights := rights()}.
info(#grant{fids = Fids, closing = Closing, owners = Owners, aliases = Live,
            in_flight = InFlight, refused = Refused, rights = Rights}) ->
    #{fids => map_size(Fids) + map_size(Closing), owners => map_size(Owners),
      waiting => length([Alias || Alias := #live{what = {keeper, _}} <- Live]),
      in_flight => InFlight, aliases => map_size(Live), refused => Refused, rights => Rights}.

-doc """
The most requests a grant holds at once, the bound of `in_flight`, so a
keeper can bound what one grant's waiting requests make it hold.
""".
-spec in_flight_max() -> pos_integer().
in_flight_max() ->
    ?IN_FLIGHT_MAX.

-doc """
What one fid at its largest adds to a grant of `Pool` fids whose tree's largest
node or handle is `Node` (docs/design-files.md, "What a fid denotes"), in words,
measured on the grant's own records rather than counted by hand: `Heap`, the
words on the grant's heap, which a collection copies, and `OffHeap`, those of the
binaries past ERTS's limit for a binary on the heap, which it does not. The fid
is its record with a qid of a u64 path, an entry whose name of the longest
length owns its bytes, and `Node` as its node, its entry's directory and its
handle; the entries it adds to the fid table or the closing table, with its
#closing{}, and to its owner's set, with that owner's record, its monitor and
its entry in the owners table when it is the owner's only fid; and its two
nodes as keys of `named` and of `held`. Each map entry costs what an entry of
a map of `Pool` entries costs.
""".
-spec fid_words(pos_integer(), term()) -> {Heap :: pos_integer(), OffHeap :: non_neg_integer()}.
fid_words(Pool, Node) ->
    Name = binary:copy(<<"x">>, ?ERX_NAME_MAX),
    Fid = #fid{owner = self(), at = {Node, {255, 16#ffffffff, 16#ffffffffffffffff}, {Node, Name}},
               open = {open, Node}},
    Closing = #closing{fid = Fid, alias = make_ref(), request = {remove, 0}, answer = closed, waits = 0},
    Owner = #owner{monitor = make_ref(), fids = #{}},
    Terms = [Closing, Owner, Node, Node, Node, Node],
    Entries = 7,
    EntryWords = erts_debug:flat_size(maps:from_keys(lists:seq(1, Pool), [])) / Pool,
    {ceil(erts_debug:flat_size(Terms) + Entries * EntryWords), off_heap_words(Terms)}.

%% The words of the binaries Term holds off the heap, each as include_shared_binaries
%% counts it once for every reference (erl_bits.h, ERL_ONHEAP_BINARY_LIMIT).
off_heap_words(Binary) when is_binary(Binary), byte_size(Binary) > 64 ->
    ceil(byte_size(Binary) / erlang:system_info(wordsize));
off_heap_words(Tuple) when is_tuple(Tuple) ->
    off_heap_words(tuple_to_list(Tuple));
off_heap_words(Map) when is_map(Map) ->
    off_heap_words(maps:to_list(Map));
off_heap_words([Head | Tail]) ->
    off_heap_words(Head) + off_heap_words(Tail);
off_heap_words(_) ->
    0.

%% The one pair of functions that add and remove live aliases, and with them
%% count the requests' window: a held request takes a slot; a flush and a
%% clunk wait beside the window, so a full window can still be flushed and
%% clunked (design-files.md, "Bounds"), and a keeper alias is the grant's own.
live(Alias, What, #grant{aliases = Live, in_flight = InFlight} = Grant)
  when not is_map_key(Alias, Live) ->
    Grant#grant{aliases = Live#{Alias => #live{what = What}}, in_flight = InFlight + window(What)}.

unlive(Alias, #grant{aliases = Live, in_flight = InFlight} = Grant) ->
    {#live{what = What} = Entry, Rest} = maps:take(Alias, Live),
    {Entry, Grant#grant{aliases = Rest, in_flight = InFlight - window(What)}}.

window(#held{}) -> 1;
window(_) -> 0.

%% A held request's answer, from its keeper or its keeper's end: the keeper
%% alias ends, the request is answered, then its flush, and when it was the
%% last held request of a closing fid, that fid's clunk runs.
settle_held(KeeperAlias, ClientAlias, Reply, Grant) ->
    {_, #grant{aliases = Live} = Grant1} = unlive(KeeperAlias, Grant),
    #{ClientAlias := #live{what = #held{fid = Fid, request = Request}}} = Live,
    then(answer(ClientAlias, Request, Reply, Grant1), fun(G) -> one_wait_less(Fid, G) end).

%% Answers a live alias, then the flush waiting on it, which is live too and
%% so may have a flush of its own.
answer(Alias, Request, Reply, Grant) ->
    {#live{flush = Flush}, Grant1} = unlive(Alias, Grant),
    then(finish(Alias, Request, Reply, Grant1), fun(G) -> answer_flush(Flush, G) end).

answer_flush(none, Grant) ->
    {[], Grant};
answer_flush(Flush, #grant{aliases = Live} = Grant) ->
    #{Flush := #live{what = {flush, Old}}} = Live,
    answer(Flush, {flush, Old}, ok, Grant).

one_wait_less(Fid, #grant{closing = Closing} = Grant) ->
    case Closing of
        #{Fid := #closing{waits = 1} = Ending} ->
            run_clunk(Fid, Ending, Grant#grant{closing = maps:remove(Fid, Closing)});
        #{Fid := #closing{waits = Waits} = Ending} ->
            {[], Grant#grant{closing = Closing#{Fid := Ending#closing{waits = Waits - 1}}}};
        #{} ->
            {[], Grant}
    end.

%% A clunk or a remove of Fid, the client's or, with Alias none, the grant's own
%% at its owner's end (rule 5). The fid leaves the fid table, so a later request
%% on it is ebadf while its number stays taken; each of its requests a keeper
%% holds is flushed; and its clunk runs once the last of them is answered, at
%% once when there are none. Answer is what the ending gets once its clunk has
%% run (#closing{}): a remove's unlink or its refusal, as remove(5) says. A fid
%% the grant does not hold, or one already closing, is answered at once.
end_fid(Alias, Fid, Request, Answer, #grant{fids = Fids, aliases = Live} = Grant) ->
    case maps:take(Fid, Fids) of
        {Record, Rest} ->
            Waits = [Held || Held := #live{what = #held{fid = Of}} <- Live, Of =:= Fid],
            Ending = #closing{fid = Record, alias = Alias, request = Request,
                              answer = Answer, waits = length(Waits)},
            Grant1 = live_ending(Alias, Grant#grant{fids = Rest}),
            case Waits of
                [] ->
                    run_clunk(Fid, Ending, Grant1);
                [_ | _] ->
                    #grant{closing = Closing} = Grant1,
                    drain(lists:foldl(fun flush_at_keeper/2,
                                      Grant1#grant{closing = Closing#{Fid => Ending}}, Waits))
            end;
        error ->
            finish(Alias, Request, unheld(Answer), Grant)
    end.

unheld(closed) -> {error, ebadf};
unheld(Refusal) -> Refusal.

live_ending(none, Grant) -> Grant;
live_ending(Alias, Grant) -> live(Alias, ending, Grant).

%% Ends a fid whose held requests are all answered: the tree's clunk runs, and
%% the ending is answered what the clunk answered, or a remove what its unlink
%% or its refusal decided.
run_clunk(Fid, #closing{fid = Record, alias = Alias, request = Request, answer = Answer}, Grant) ->
    {Closed, Grant1} = close_fid(Fid, Record, Grant),
    Reply = case Answer of
                closed -> Closed;
                _ -> Answer
            end,
    answer_ending(Alias, Request, Reply, Grant1).

%% A remove unlinks when it is taken, before its fid's held requests settle,
%% so a request after it sees the name gone; only its clunk waits for them.
%% It unlinks the entry its fid was walked by, only while that entry
%% still names the fid's node (the tree decides, in one step); the root has no
%% entry to unlink.
unlinked({_, _, root}, Grant) ->
    {{error, einval}, Grant};
unlinked({Node, _, {Dir, Name}}, Grant) ->
    change(unlink, [Dir, Name, {node, Node}], Grant).

answer_ending(none, _, _, Grant) -> drain(Grant);
answer_ending(Alias, Request, Reply, Grant) -> answer(Alias, Request, Reply, Grant).

%% The funnel. Every message from another domain arrives in the envelope of
%% edit 16, {erx_origin, D, Frame}, where D is the creation of the connection
%% the frame came on. A grant takes a frame only from its client domain:
%%
%% * a grant for another domain takes it only in an envelope whose D is the
%%   client's id;
%% * a grant for the server's own domain takes it only bare.
%%
%% Every other message is dropped. A frame taken is admitted only if the grammar
%% accepts it, its alias and its owner are the client domain's, and it does not
%% write on a read-only grant. A frame without an alias, or with one not of the
%% client's domain, has no one the grant may answer and is dropped: the grant
%% answers only its own client, never a third domain on a client's behalf.
decode({erx_origin, Client, Frame}, #grant{client = Client} = Grant)
  when is_integer(Client) ->
    decode_frame(Frame, Grant);
decode({erx_origin, _, _}, _) ->
    drop;
decode(Frame, #grant{client = own} = Grant) ->
    decode_frame(Frame, Grant);
decode(_, _) ->
    drop.

decode_frame(Frame, #grant{client = Client, rights = Rights}) ->
    case erx_9p_grammar:decode_request_frame(Frame) of
        error ->
            drop;
        {error, Alias, Posix} ->
            case of_client(Alias, Client) of
                true -> {refuse, Alias, Posix, none};
                false -> drop
            end;
        {ok, Alias, Owner, Request} ->
            case {of_client(Alias, Client), of_client(Owner, Client)} of
                {false, _} ->
                    drop;
                {true, false} ->
                    {refuse, Alias, einval, none};
                {true, true} ->
                    case Rights =:= rw orelse not erx_9p_grammar:writes(Request) of
                        true -> {admit, Alias, Owner, Request};
                        false -> {refuse, Alias, erofs, Request}
                    end
            end
    end.

%% Whether a name a frame carries, its alias or its owner, is the client
%% domain's: of this node for the server's own domain, and for another domain of
%% that domain's id, the creation erx_dist:owner/1 reads from the name. Both
%% this check and the envelope's D compare creations alone, so they hold only
%% while no connection but the client's lane carries the client's id as its
%% creation; a node of another machine connected to an exposed domain chooses
%% its own creation (a security residual in TODO.md).
of_client(Name, own) -> node(Name) =:= node();
of_client(Name, Client) -> erx_dist:owner(Name) =:= Client.

%% A flush and a clunk or a remove are admitted at any bound, since each ends
%% something the window already counts or a fid, which ends once; every other
%% request takes a slot of the window, or is emfile when it is full. A flush of
%% a keeper alias, of a flush or of no live alias waits for nothing and is
%% answered at once.
admit(Alias, _, {flush, Old} = Request, #grant{aliases = Live} = Grant) ->
    case Live of
        #{Old := #live{what = {keeper, _}}} -> finish(Alias, Request, ok, Grant);
        #{Old := #live{what = {flush, _}}} -> finish(Alias, Request, ok, Grant);
        #{Old := #live{flush = none} = Entry} -> flush_waits(Alias, Old, Entry, Grant);
        #{Old := #live{}} -> dropped(Grant);
        #{} -> finish(Alias, Request, ok, Grant)
    end;
admit(Alias, _, {clunk, Fid} = Request, Grant) ->
    end_fid(Alias, Fid, Request, closed, Grant);
admit(Alias, _, {remove, Fid} = Request, #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{at = At}} ->
            {Answer, Grant1} = unlinked(At, Grant),
            end_fid(Alias, Fid, Request, Answer, Grant1);
        #{} -> finish(Alias, Request, {error, ebadf}, Grant)
    end;
admit(Alias, _, Request, #grant{in_flight = InFlight, in_flight_max = Max} = Grant)
  when InFlight >= Max ->
    finish(Alias, Request, {error, emfile}, Grant);
admit(Alias, Owner, Request, Grant) ->
    Directories = erx_9p_grammar:directory_fids(Request),
    case lists:all(fun(Fid) -> directory_or_unheld(Fid, Grant) end, Directories) of
        true ->
            case dispatch(Owner, Request, Grant) of
                {wait, Keeper, Held, Grant1} -> hand_over(Alias, Request, Keeper, Held, Grant1);
                {Reply, Grant1} -> finish(Alias, Request, Reply, Grant1, Grant)
            end;
        false ->
            finish(Alias, Request, {error, enotdir}, Grant)
    end.

%% Whether Fid, one that erx_9p_grammar:directory_fids/1 lists for a request
%% (the directory a make, an unlink or a rename acts in, or the fid a listing
%% reads, as the protocol table marks them), may be dispatched: true when it
%% names a directory or the grant does not hold it. A request failing this is
%% enotdir before dispatch, so no callback is handed a node that is no
%% directory as one, since a node's qid, recorded when its fid was walked,
%% keeps its type while the node lives (design-files.md, qid identity). A walk
%% checks each name it passes itself (walk_step/3). A fid the grant does not
%% hold is left to dispatch/3, which answers ebadf.
directory_or_unheld(Fid, #grant{fids = Fids}) ->
    case Fids of
        #{Fid := #fid{at = {_, {Type, _, _}, _}}} -> Type band ?ERX_P9_QTDIR =/= 0;
        #{} -> true
    end.

%% A request whose callback answered {wait, Keeper, Held} goes to Keeper, in
%% flight until Keeper answers it (answered/3) or ends (down/3). A keeper
%% that is not a process of the server's own runtime, or is the grant
%% itself, which would never answer, is eio.
hand_over(Alias, {_, Fid, _, _} = Request, Keeper, Held, #grant{self = Self} = Grant)
  when is_pid(Keeper), node(Keeper) =:= node(), Keeper =/= Self ->
    #grant{effects = Effects} = Grant1 =
        live(Alias, #held{fid = Fid, request = Request, keeper = Keeper}, Grant),
    drain(Grant1#grant{effects = [{wait, Alias, Keeper, Held} | Effects]});
hand_over(Alias, Request, _, _, Grant) ->
    finish(Alias, Request, {error, eio}, Grant).

%% A flush waits for the live alias it names, Entry (rule 4): the flush of a
%% held request goes on to its keeper; one of a clunk waits for the clunk's
%% answer.
flush_waits(Alias, Old, Entry, #grant{aliases = Live} = Grant) ->
    Waiting = Grant#grant{aliases = Live#{Old := Entry#live{flush = Alias}}},
    drain(flush_at_keeper(Old, live(Alias, {flush, Old}, Waiting))).

%% The keeper that holds a request hears of its flush, the client's or its
%% fid's clunk's, once, and after the request, since both come from the grant;
%% it answers the request, and the flush is answered after it. A flush of a
%% live alias that is no held request reaches no keeper.
flush_at_keeper(Alias, #grant{aliases = Live, effects = Effects} = Grant) ->
    case Live of
        #{Alias := #live{what = #held{flushed = false, keeper = Keeper, at = KeeperAlias} = Held} = Entry}
          when is_reference(KeeperAlias) ->
            Flushed = Entry#live{what = Held#held{flushed = true}},
            Grant#grant{aliases = Live#{Alias := Flushed},
                        effects = [{flush, Keeper, KeeperAlias} | Effects]};
        #{} ->
            Grant
    end.

%% Every answer leaves through here, held to its request by the grammar's
%% reply check. An operation is built whole before it is kept: dispatch/3
%% answers its reply with the grant it would leave (Built), and only a reply
%% the check accepts keeps it. A reply the check rejects reaches the client
%% as eio and keeps the grant as it was before the request (Before), its
%% effects included, as a refusal does, but for a tree of the grant's own,
%% whose step has run and is kept (kept_when_rejected/3).
%% Every qid the grant records travels in the reply that records it (attach,
%% walk, lcreate) or is the root's, which new/1 admitted before the grant took
%% any request (a walk from NOFID), so a callback's malformed answer, a qid
%% included, leaves no fid or open behind. Callers of finish/4 have nothing to undo: a
%% refusal, a keeper's answer, or a clunk or a remove, whose fid has ended
%% through run_clunk/3 whatever its answer, as clunk(5) says.
finish(Alias, Request, Reply, Grant) ->
    finish(Alias, Request, Reply, Grant, Grant).

finish(Alias, Request, Reply, Built, Before) ->
    {Checked, Grant} = case accepted(Request, Reply) of
                           true -> {Reply, Built};
                           false -> {{error, eio}, kept_when_rejected(Request, Built, Before)}
                       end,
    Grant1 = case Checked of
                 {error, _} -> count_refusal(Grant);
                 _ -> Grant
             end,
    {Effects, Grant2} = drain(Grant1),
    case Grant2 of
        #grant{ended = true} -> {Effects, Grant2};
        #grant{} -> {Effects ++ [{reply, Alias, Checked}], Grant2}
    end.

%% The holds a step took stay taken when its grant is dropped: they are the
%% tree's, and drain/1 forgets those no fid of Before names. An own tree is
%% kept as the step left it, since what the tree did is not undone.
kept_when_rejected(_, #grant{held = Held, loose = Loose, fs = Fs}, Before) ->
    Before#grant{held = Held, loose = Loose, fs = Fs}.

%% A refusal of a frame the grammar did not decode (Request none) is the
%% grant's own {error, Posix}; every other reply is checked against its request.
accepted(none, _) ->
    true;
accepted(Request, Reply) ->
    case erx_9p_grammar:decode_reply(Request, Reply) of
        {ok, _} -> true;
        {error, eio} -> false
    end.

count_refusal(#grant{refused = Refused} = Grant) ->
    Grant#grant{refused = Refused + 1}.

drain(Grant) ->
    #grant{effects = Effects} = Grant1 = forget_loose(Grant),
    {lists:reverse(Effects), Grant1#grant{effects = []}}.

%% A tree kept in a process of its own takes forget as a cast, so the grant's
%% later walks reach it after the forget; an own tree's forget runs here.
forget_loose(#grant{loose = []} = Grant) ->
    Grant;
forget_loose(#grant{loose = Loose, held = Held, named = Named} = Grant) ->
    Unnamed = [Node || Node <- lists:usort(Loose), is_map_key(Node, Held),
                       not is_map_key(Node, Named)],
    Forgotten = lists:foldl(fun(Node, G) -> element(2, tree(forget, [Node], ok, G)) end,
                            Grant, Unnamed),
    Forgotten#grant{held = maps:without(Unnamed, Held), loose = []}.

%% Each admitted operation, as {Reply, Grant}, or {wait, Keeper, Request,
%% Grant} for a read or a write its tree's keeper answers: only on_open/3
%% builds that shape, from call/3, so no other callback's answer is a wait. Every fid a
%% request names is looked up here; a fid the grant does not hold is ebadf.
dispatch(_, {version, Msize, Version}, #grant{msize_max = Max} = Grant) ->
    {version(Msize, Version, Max), Grant};
dispatch(Owner, {attach, Fid, Afid, _, Aname, _}, Grant) ->
    attach(Owner, Fid, Afid, Aname, Grant);
dispatch(Owner, {walk, Fid, NewFid, Names}, Grant) ->
    walk(Owner, Fid, NewFid, Names, Grant);
dispatch(_, {getattr, Fid, _}, Grant) ->
    on_node(Fid, Grant, fun(Node, G) -> tree(getattr, [Node], G) end);
dispatch(_, {readlink, Fid}, Grant) ->
    on_node(Fid, Grant, fun(Node, G) -> tree(readlink, [Node], {error, einval}, G) end);
dispatch(_, {statfs, Fid}, Grant) ->
    on_node(Fid, Grant, fun(_, G) -> tree(statfs, [], G) end);
dispatch(_, {lopen, Fid, Flags}, Grant) ->
    lopen(Fid, Flags, Grant);
dispatch(_, {lcreate, _, _, _, _, _} = Request, Grant) ->
    lcreate(Request, Grant);
dispatch(_, {read, Fid, Offset, Count}, Grant) ->
    on_open(Fid, Grant, fun(Handle) -> {read, Handle, Offset, Count} end);
dispatch(_, {write, Fid, Offset, Data}, Grant) ->
    on_open(Fid, Grant, fun(Handle) -> {write, Handle, Offset, Data} end);
dispatch(_, {readdir, Fid, Offset, Count}, Grant) ->
    on_open(Fid, Grant, fun(Handle) -> {readdir, Handle, Offset, Count} end);
dispatch(_, {fsync, Fid, _Datasync}, Grant) ->
    on_open(Fid, Grant, fun(Handle) -> {fsync, Handle} end);
dispatch(Owner, {mkdir, Dfid, Name, Mode, _Gid}, Grant) ->
    make(Dfid, Name, {directory, Mode band 8#7777, Owner}, Grant);
dispatch(_, {symlink, Fid, Name, Target, _Gid}, Grant) ->
    make(Fid, Name, {symlink, Target}, Grant);
dispatch(_, {link, Dfid, Fid, Name}, Grant) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> make(Dfid, Name, {link, Node}, Grant);
        error -> {{error, ebadf}, Grant}
    end;
dispatch(_, {mknod, Dfid, Name, Mode, Major, Minor, _Gid}, Grant) ->
    make(Dfid, Name, {node, Mode, Major, Minor}, Grant);
dispatch(_, {unlinkat, Dfid, Name, Flags}, Grant) ->
    Kind = case Flags band ?ERX_P9_AT_REMOVEDIR of
               0 -> file;
               _ -> directory
           end,
    change_on_node(Dfid, Grant, unlink, fun(Dir) -> [Dir, Name, Kind] end);
dispatch(_, {renameat, OldDfid, OldName, NewDfid, NewName}, Grant) ->
    case node_of(NewDfid, Grant) of
        {ok, NewDir} ->
            change_on_node(OldDfid, Grant, rename,
                           fun(OldDir) -> [OldDir, OldName, NewDir, NewName] end);
        error ->
            {{error, ebadf}, Grant}
    end;
dispatch(_, {setattr, Fid, Attr}, #grant{fids = Fids} = Grant) ->
    %% A size change through an opened fid is decided by that open's access;
    %% through an unopened fid, by the node's.
    case Fids of
        #{Fid := #fid{open = {open, _}}} -> on_open(Fid, Grant, fun(Handle) -> {setattr, Handle, Attr} end);
        #{} -> change_on_node(Fid, Grant, setattr, fun(Node) -> [{node, Node}, Attr] end)
    end;
dispatch(_, _, Grant) ->
    %% auth, the extended attributes and the locks are not served.
    {{error, enotsup}, Grant}.

version(Msize, _, _) when Msize < ?MSIZE_MIN -> {error, einval};
version(Msize, ?VERSION, Max) -> {ok, min(Msize, Max), ?VERSION};
version(Msize, _, Max) -> {ok, min(Msize, Max), <<"unknown">>}.

attach(_, _, Afid, _, Grant) when Afid =/= ?ERX_P9_NOFID ->
    %% auth is not served, so the grant holds no fid an Afid could name.
    {{error, ebadf}, Grant};
%% An attach names the grant's tree, or is enoent, and starts at the root the
%% start fixed. Its reply carries the root's current qid, which the tree answers
%% afresh: only its version may differ from the admitted one, and an answer
%% naming another tree, type or path is eio, making no fid.
attach(Owner, Fid, _, Tree, #grant{tree = Tree, root = {Node, {Type, _, Path}, root}} = Grant) ->
    case new_fid_admissible(Fid, Grant) of
        ok ->
            case tree(root, [], Grant) of
                {{ok, Tree, _, {Type, _, Path} = Qid}, Grant1} ->
                    {{ok, Qid}, add_fid(Fid, Owner, {Node, Qid, root}, Grant1)};
                {_, Grant1} ->
                    {{error, eio}, Grant1}
            end;
        {error, _} = Error ->
            {Error, Grant}
    end;
attach(_, _, _, _, Grant) ->
    {{error, enoent}, Grant}.

%% A walk starts at a fid that is not open, or at the grant's root for NOFID,
%% and names a new fid that is not in use, unless it is the same fid. It names
%% the result only when every name was walked; one that stops after the first
%% name lists the qids it walked and changes nothing.
walk(Owner, Fid, NewFid, Names, Grant) ->
    case walk_start(Fid, Grant) of
        {ok, At} ->
            Admissible = case NewFid of
                             Fid -> ok;
                             _ -> new_fid_admissible(NewFid, Grant)
                         end,
            case Admissible of
                ok -> walked(Owner, Fid, NewFid, walk_names(Names, At, [], Grant));
                {error, _} = Error -> {Error, Grant}
            end;
        {error, _} = Error ->
            {Error, Grant}
    end.

%% Where a walk starts: NOFID, which names no fid (the grammar's fid kind
%% excludes it, so no fid of the table is NOFID), starts at the root the start
%% admitted, as a fid an attach had just made; any other fid is one the grant
%% holds and has not opened.
walk_start(?ERX_P9_NOFID, #grant{root = Root}) ->
    {ok, Root};
walk_start(Fid, #grant{fids = Fids}) ->
    case Fids of
        #{Fid := #fid{open = {open, _}}} -> {error, einval};
        #{Fid := #fid{at = At}} -> {ok, At};
        #{} -> {error, ebadf}
    end.

%% The walk's grant carries the holds its steps took, kept or not.
walked(_, _, _, {stopped, [], Posix, Grant}) ->
    {{error, Posix}, Grant};
walked(_, _, _, {stopped, Qids, _, Grant}) ->
    {{ok, lists:reverse(Qids)}, Grant};
walked(_, Fid, Fid, {done, At, Qids, Grant}) ->
    {{ok, lists:reverse(Qids)}, set_at(Fid, At, Grant)};
walked(Owner, _, NewFid, {done, At, Qids, Grant}) ->
    {{ok, lists:reverse(Qids)}, add_fid(NewFid, Owner, At, Grant)}.

walk_names([], At, Qids, Grant) ->
    {done, At, Qids, Grant};
walk_names([Name | Names], At, Qids, Grant) ->
    case walk_step(Name, At, Grant) of
        {ok, {_, Qid, _} = At1, Grant1} -> walk_names(Names, At1, [Qid | Qids], Grant1);
        {error, Posix, Grant1} -> {stopped, Qids, Posix, Grant1}
    end.

%% Only a directory is walked from, so a walk that reaches a symbolic link
%% stops at its next name and the callback is never asked to follow one (F2).
%% Every name is a plain one: the grammar refuses `..`, so a walk only
%% descends and never asks for a parent. A node the callback answers is held
%% from that answer on.
walk_step(_, {_, {Type, _, _}, _}, Grant) when Type band ?ERX_P9_QTDIR =:= 0 ->
    {error, enotdir, Grant};
walk_step(Name, {Dir, _, _}, Grant) ->
    Kept = kept_name(Name),
    case tree(walk, [Dir, Kept], Grant) of
        {{ok, Node, Qid}, #grant{held = Held, loose = Loose} = Grant1} ->
            {ok, {Node, Qid, {Dir, Kept}},
             Grant1#grant{held = Held#{Node => []}, loose = [Node | Loose]}};
        {Other, Grant1} ->
            {error, Posix} = failed(Other),
            {error, Posix, Grant1}
    end.

%% lopen opens an unopened fid in place; a fid at a symbolic link is never
%% opened (eloop), so no open acts on a link the client has not seen, and
%% with O_DIRECTORY a fid at anything but a directory is never opened
%% (enotdir), so its O_TRUNC empties nothing, as FreeBSD's vn_open_vnode
%% refuses both before it opens.
lopen(Fid, Flags, #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{open = {open, _}}} ->
            {{error, einval}, Grant};
        #{Fid := #fid{at = {_, {Type, _, _}, _}}} when Type band ?ERX_P9_QTSYMLINK =/= 0 ->
            {{error, eloop}, Grant};
        #{Fid := #fid{at = {_, {Type, _, _}, _}}}
          when Flags band ?ERX_P9_O_DIRECTORY =/= 0, Type band ?ERX_P9_QTDIR =:= 0 ->
            {{error, enotdir}, Grant};
        #{Fid := #fid{at = {Node, Qid, _}}} ->
            case tree(open, [Node, Flags], Grant) of
                {{ok, Handle}, Grant1} -> {{ok, Qid, ?IOUNIT}, opened(Fid, Handle, Grant1)};
                {Other, Grant1} -> {failed(Other), Grant1}
            end;
        #{} ->
            {{error, ebadf}, Grant}
    end.

%% lcreate turns a directory's unopened fid into the opened fid of the file
%% Name names: one make of {file, Mode, Flags} creates it, or without O_EXCL
%% opens the regular file already there, and either way counts the open. Its
%% reply is checked here, before the open is recorded: a handle the tree
%% opened for a reply the check rejects is held by no fid, so it is clunked
%% at once, since dropping the grant this operation built cannot release
%% what the tree acquired.
lcreate({lcreate, Fid, Name, Flags, Mode, _} = Request,
        #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{open = {open, _}}} ->
            {{error, einval}, Grant};
        #{Fid := #fid{at = {Dir, _, _}}} ->
            What = {file, Mode band 8#7777, Flags},
            Kept = kept_name(Name),
            case tree(make, [Dir, Kept, What], {error, eperm}, Grant) of
                {{ok, Node, Qid, Handle}, Made} ->
                    Reply = {ok, Qid, ?IOUNIT},
                    case accepted(Request, Reply) of
                        true ->
                            Grant1 = set_at(Fid, {Node, Qid, {Dir, Kept}}, Made),
                            {Reply, opened(Fid, Handle, Grant1)};
                        false ->
                            {_, Clunked} = tree(clunk, [Handle], Made),
                            {{error, eio}, Clunked}
                    end;
                {Other, Made} ->
                    {failed(Other), Made}
            end;
        #{} ->
            {{error, ebadf}, Grant}
    end.

make(Dfid, Name, What, Grant) ->
    case node_of(Dfid, Grant) of
        {ok, Dir} ->
            case change(make, [Dir, Name, What], Grant) of
                {{ok, _Node, Qid}, Grant1} -> {made_reply(What, Qid), Grant1};
                {{error, _} = Error, Grant1} -> {Error, Grant1}
            end;
        error ->
            {{error, ebadf}, Grant}
    end.

made_reply({link, _}, _) -> ok;
made_reply(_, Qid) -> {ok, Qid}.

%% A callback that changes the tree answers ok, or for make the node it made;
%% a tree without the callback keeps nothing of that kind (eperm). A handle's
%% change is the tree's, behind the handle; an own tree's is the grant's next tree.
change_on_node(Fid, Grant, Callback, Arguments) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> change(Callback, Arguments(Node), Grant);
        error -> {{error, ebadf}, Grant}
    end.

change(Callback, Arguments, Grant) ->
    answered_by(fun(Answer) -> changed(Callback, Answer) end,
                tree(Callback, Arguments, {error, eperm}, Grant)).

changed(make, {ok, Node, Qid}) -> {ok, Node, Qid};
changed(make, Other) -> failed(Other);
changed(_, Answer) -> done(Answer).

on_node(Fid, Grant, Read) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> Read(Node, Grant);
        error -> {{error, ebadf}, Grant}
    end.

%% An operation of an open file needs an opened fid; an unopened one has no
%% handle to give it (ebadf).
on_open(Fid, #grant{fids = Fids} = Grant, Call) ->
    case Fids of
        #{Fid := #fid{open = {open, Handle}}} ->
            case call(Call(Handle), Grant) of
                {{wait, Keeper, Request}, Grant1} -> {wait, Keeper, Request, Grant1};
                {Answer, Grant1} -> {Answer, Grant1}
            end;
        #{} -> {{error, ebadf}, Grant}
    end.

%% The one way to the tree's callbacks: Callback with Arguments and the
%% grant's handle, or its own tree, which the callback's answer replaces
%% (docs/design-files.md, "A handle, or a tree of the grant's own"). An own
%% tree's answer that is no pair is a fault of the module and ends the grant.
%% A tree without an optional callback answers Absent and changes nothing.
tree(Callback, Arguments, Grant) ->
    tree(Callback, Arguments, none, Grant).

tree(Callback, Arguments, Absent, #grant{module = Module, fs = Fs} = Grant) ->
    case erlang:function_exported(Module, Callback, length(Arguments) + 1) of
        false when Absent =/= none ->
            {Absent, Grant};
        _ ->
            case Fs of
                {ok, Handle} ->
                    {apply(Module, Callback, Arguments ++ [Handle]), Grant};
                {own, Tree} ->
                    {Answer, Tree1} = apply(Module, Callback, Arguments ++ [Tree]),
                    {Answer, Grant#grant{fs = {own, Tree1}}}
            end
    end.

node_of(Fid, #grant{fids = Fids}) ->
    case Fids of
        #{Fid := #fid{at = {Node, _, _}}} -> {ok, Node};
        #{} -> error
    end.

%% A name as the fid keeps it: its own bytes, so a name the request carved
%% from a larger binary does not keep that binary alive for the fid's life
%% (docs/design-files.md, "What a fid denotes").
kept_name(Name) ->
    binary:copy(Name).

set_at(Fid, At, #grant{fids = Fids} = Grant) ->
    #{Fid := #fid{open = none} = Record} = Fids,
    place(Fid, Record, At, Grant).

%% The one function that writes a fid's place. Fid's record becomes Record with
%% place At. `named` gains At's nodes and loses the nodes of Fid's previous place
%% in the fid table; a new fid has no previous place.
place(Fid, Record, At, #grant{fids = Fids} = Grant) ->
    Before = case Fids of
                 #{Fid := #fid{at = Old}} -> place_nodes(Old);
                 #{} -> []
             end,
    recount(Before, place_nodes(At), Grant#grant{fids = Fids#{Fid => Record#fid{at = At}}}).

%% The nodes a place names for the tree's holds: its node and its entry's
%% directory, which a remove through the fid unlinks from.
place_nodes({Node, _, root}) -> [Node];
place_nodes({Node, _, {Dir, _}}) -> [Node, Dir].

%% The one function that changes `named`, called by place/4 as a fid is made
%% or moved and by close_fid/3 as it ends: New's nodes arrive, Old's leave,
%% and a node no fid names any more is loose.
recount(Old, New, #grant{named = Named, loose = Loose} = Grant) ->
    Arrived = lists:foldl(fun(Node, N) -> maps:update_with(Node, fun(C) -> C + 1 end, 1, N) end,
                          Named, New),
    {Left, Loose1} = lists:foldl(fun(Node, {N, L}) ->
                                         case N of
                                             #{Node := 1} -> {maps:remove(Node, N), [Node | L]};
                                             #{Node := C} -> {N#{Node := C - 1}, L}
                                         end
                                 end, {Arrived, Loose}, Old),
    Grant#grant{named = Left, loose = Loose1}.

%% A new fid is refused while its number is alive, a closing fid's included
%% (einval, as QEMU answers a fid in use), and when the pool is full (emfile).
new_fid_admissible(Fid, #grant{fids = Fids, closing = Closing, pool = Pool}) ->
    if
        is_map_key(Fid, Fids) orelse is_map_key(Fid, Closing) -> {error, einval};
        map_size(Fids) + map_size(Closing) >= Pool -> {error, emfile};
        true -> ok
    end.

%% With set_at/3, opened/3 and end_fid/5, the only functions that change the
%% fid table; add_fid/4, close_fid/3 and owner_down/2 also change the owners
%% and their monitors: an owner is recorded, and monitored, exactly while it
%% owns a fid and lives.
add_fid(Fid, Owner, At, Grant) ->
    #grant{owners = Owners, effects = Effects} = Grant1 = place(Fid, #fid{owner = Owner}, At, Grant),
    case Owners of
        #{Owner := #owner{fids = Owned} = Record} ->
            Grant1#grant{owners = Owners#{Owner := Record#owner{fids = Owned#{Fid => []}}}};
        #{} ->
            Grant1#grant{owners = Owners#{Owner => #owner{monitor = pending, fids = #{Fid => []}}},
                         effects = [{monitor, Owner} | Effects]}
    end.

%% Ends a fid that end_fid/5 took from the fid table, as {Closed, Grant}:
%% Closed is ok for an unopened fid, and for an opened one what the tree's
%% clunk of its handle answered, ok or the errno of what the close could not
%% complete. The fid ends either way, and leaves its owner, unless the owner
%% ended first (owner_down/2).
close_fid(Fid, #fid{owner = Owner, open = Open, at = At}, Grant) ->
    {Closed, #grant{owners = Owners, effects = Effects} = Grant1} = closed(Open, recount(place_nodes(At), [], Grant)),
    case Owners of
        #{Owner := #owner{monitor = Ref, fids = #{Fid := _} = Owned} = Record} ->
            case maps:remove(Fid, Owned) of
                Left when map_size(Left) =:= 0 ->
                    {Closed, Grant1#grant{owners = maps:remove(Owner, Owners),
                                          effects = [{demonitor, Ref} | Effects]}};
                Left ->
                    {Closed, Grant1#grant{owners = Owners#{Owner := Record#owner{fids = Left}}}}
            end;
        #{} ->
            {Closed, Grant1}
    end.

%% An opened fid keeps its open's handle, its one name: two opens whose
%% handles are equal stay two opens, each clunked once, at its fid's end.
opened(Fid, Handle, #grant{fids = Fids} = Grant) ->
    #{Fid := Record} = Fids,
    Grant#grant{fids = Fids#{Fid := Record#fid{open = {open, Handle}}}}.

closed(none, Grant) ->
    {ok, Grant};
closed({open, Handle}, Grant) ->
    answered_by(fun done/1, tree(clunk, [Handle], Grant)).
