%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_grant).
-moduledoc """
The pure core of one `erx_fs` grant (docs/design-files.md#serving-the-erx_fs-behaviour).

A grant serves one client domain's requests on one tree. This module holds
everything the grant knows, its fid table, the owners it monitors, its open
files and the requests it has in flight, and decides each step:
`handle_frame/2` takes one message the grant received and returns the effects
to perform, in order, and the next state. `erx_fs`, the process shell,
performs them:

* `{reply, Alias, Reply}`: send `{erx_9p, Alias, Reply}` to `Alias`;
* `{monitor, Owner}`: monitor `Owner` and hand the reference back with
  `monitored/3` before the next step;
* `{demonitor, Ref}`: `erlang:demonitor(Ref, [flush])`;
* `{start_file, Node, Module, Fs}`: start the file process,
  linked to the grant, and hand its pid and tag back with `file_started/4`
  before the next step;
* `{run, Process, Tag, Job}`: send `{Tag, Job}` to a file process,
  which performs it with `run_job/3`.

The core calls the tree's callback module directly for everything but an open
file's reads, writes, listings, size changes, syncs and clunks, which its file process
runs in turn and answers with `{erx_fs_file, Tag, Alias, Reply}`; a walk asks
the tree one name at a time and each answer decides the next question. The core
reads no other state and sends nothing. Every callback receives the tree's
handle `Fs`, which `init/1` answered and which never changes, and answers only
its result, never a next state, so the grant and its file processes call one
tree; an answer that is none of its callback's shapes reaches the client as
`eio`, through `failed/1` or the grammar's reply check in `finish/5`.

Every frame passes one funnel, `decode/2`, which takes the grant's rights:
dispatch receives only requests the funnel admitted, so a writing request on a
read-only grant never reaches a callback (F5).

The fid table is the one record of which fids are alive. Each fid has an owner,
fixed for its life; `owners` maps each owner of a live fid to its monitor and
its set of fids, and holds no other process, so the grant never monitors more
processes than it holds fids (F10, design-files.md#fid-owners). `files` maps
each node open through one of the grant's fids to its file process and its
count of opened fids; `end_fid/2`, the one place a fid ends, releases its open,
so the grant never holds more open files than opened fids, and a file process
ends with its file's last clunk.
""".

-export([new/1, handle_frame/2, monitored/3, owner_down/3, file_started/4,
         file_answer/4, run_job/3, defer/3, complete/3, info/1]).

-export_type([grant/0, effect/0, job/0, rights/0]).

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

-type rights() :: ro | rw | rx.
-type fid() :: 0..16#fffffffe.
-type qid() :: {0..255, 0..16#ffffffff, 0..16#ffffffffffffffff}.

%% What a fid denotes: the node it was walked to, the entry it was walked by
%% (the directory of the next step, and its own Name), and the chain of
%% directories back to the grant's root, each with the name it was reached by.
%% Node operations use the node; remove uses the entry; ".." uses the chain,
%% so it returns to the directory the fid was walked through whatever renames
%% happened since, and at the root, the only step, it stays.
-type step() :: {Node :: term(), qid(), Name :: binary() | root}.
-type path() :: [step(), ...].

%% A fid is unopened, or open on Node with the tree's Handle. An open fid's
%% path never changes, since no walk starts from it.
-record(fid, {owner :: pid(),
              path :: path(),
              open = none :: none | {open, Node :: term(), Handle :: term()}}).

%% An owner's monitor is `pending` from the step that made its first fid until
%% the shell hands its reference back with monitored/3.
-record(owner, {monitor :: reference() | pending,
                fids :: #{fid() => []}}).

%% An open file: its file process, the tag its answers carry, both `pending`
%% from the step that opened it until the shell hands them back with
%% file_started/4, and the number of the grant's fids open on it.
-record(file, {process :: pid() | pending,
               tag :: reference() | pending,
               opens :: pos_integer()}).

%% A request answered outside the grant's step, the flushes waiting on it, and
%% the tag of the file process that answers it (none for one deferred by defer/3).
-record(pending, {request :: tuple(), flushes :: [reference()],
                  by = none :: reference() | none}).

-record(grant, {module :: module(),
                fs :: term(),
                rights :: rights(),
                client :: node(),
                pool :: pos_integer(),
                fids = #{} :: #{fid() => #fid{}},
                owners = #{} :: #{pid() => #owner{}},
                files = #{} :: #{term() => #file{}},
                pending = #{} :: #{reference() => #pending{}},
                in_flight = 0 :: non_neg_integer(),
                refused = 0 :: non_neg_integer(),
                effects = [] :: [effect()]}).

-opaque grant() :: #grant{}.
-type effect() :: {reply, reference(), term()}
                | {monitor, pid()}
                | {demonitor, reference()}
                | {start_file, Node :: term(), module(), Fs :: term()}
                | {run, pid(), reference(), job()}.
%% What a file process performs: a request it answers to Alias, or the
%% clunk of one of its handles, the last of which ends it.
-type job() :: {answer, reference(), call()}
             | {clunk, Handle :: term()}
             | {last_clunk, Handle :: term()}.
-type call() :: {read, Handle :: term(), non_neg_integer(), pos_integer()}
              | {write, Handle :: term(), non_neg_integer(), binary()}
              | {readdir, Handle :: term(), non_neg_integer(), pos_integer()}
              | {fsync, Handle :: term()}
              | {setattr, Handle :: term(), map()}.

-doc """
A grant with no fids. `rights` is the grant's (`ro`, `rw` or `rx`); a tree
whose module has no `write/4` callback is read-only whatever they say (F5).
`client` is the node of the domain the grant serves, `pool` its fid bound.
""".
-spec new(#{module := module(), fs := term(), rights := rights(),
            client := node(), pool => pos_integer()}) -> grant().
new(#{module := Module, fs := Fs, rights := Rights, client := Client} = Options)
  when (Rights =:= ro orelse Rights =:= rw orelse Rights =:= rx),
       is_atom(Client) ->
    Pool = maps:get(pool, Options, ?DEFAULT_POOL),
    true = is_integer(Pool) andalso Pool > 0,
    Writes = erlang:function_exported(Module, write, 4),
    #grant{module = Module, fs = Fs, client = Client, pool = Pool,
           rights = effective_rights(Rights, Writes)}.

effective_rights(rw, false) -> ro;
effective_rights(Rights, _) -> Rights.

-doc "One message the grant received, other than an owner's `DOWN` or a file process's answer.".
-spec handle_frame(term(), grant()) -> {[effect()], grant()}.
handle_frame(Frame, Grant) ->
    case decode(Frame, Grant) of
        drop ->
            drain(count_refusal(Grant));
        {refuse, Alias, Posix, Request} ->
            finish(Alias, Request, {error, Posix}, refused_remove(Request, Grant));
        {admit, Alias, Owner, Request} ->
            admit(Alias, Owner, Request, Grant)
    end.

-doc "The reference of the monitor the shell made for an `{monitor, Owner}` effect.".
-spec monitored(pid(), reference(), grant()) -> grant().
monitored(Owner, Ref, #grant{owners = Owners} = Grant) ->
    #{Owner := #owner{monitor = pending} = Record} = Owners,
    Grant#grant{owners = Owners#{Owner := Record#owner{monitor = Ref}}}.

-doc """
An owner's `DOWN`: every fid it still owns ends, as if it had sent the clunks.
A `DOWN` whose reference is not the owner's monitor changes nothing.
""".
-spec owner_down(reference(), pid(), grant()) -> {[effect()], grant()}.
owner_down(Ref, Owner, #grant{owners = Owners} = Grant) ->
    case Owners of
        #{Owner := #owner{monitor = Ref, fids = Fids}} ->
            drain(lists:foldl(fun end_fid/2, Grant, maps:keys(Fids)));
        #{} ->
            {[], Grant}
    end.

-doc """
The file process the shell started for a `{start_file, Node, _, _}` effect,
and the tag its answers carry.
""".
-spec file_started(term(), pid(), reference(), grant()) -> grant().
file_started(Node, Process, Tag, #grant{files = Files} = Grant) ->
    #{Node := #file{process = pending} = File} = Files,
    Grant#grant{files = Files#{Node := File#file{process = Process, tag = Tag}}}.

-doc """
A file process's answer to the request it was sent to `Alias`. One whose tag is
not the tag of the file process the request went to answers nothing and is counted
as refused, as any other message the grant cannot take.
""".
-spec file_answer(reference(), reference(), term(), grant()) -> {[effect()], grant()}.
file_answer(Tag, Alias, Reply, #grant{pending = Pending} = Grant) ->
    case Pending of
        #{Alias := #pending{by = Tag}} when is_reference(Tag) -> complete(Alias, Reply, Grant);
        #{} -> drain(count_refusal(Grant))
    end.

-doc """
What a file process does with one job, calling `Module` with the tree's
handle `Fs`: `{answer, Alias, Reply}` for a request, whose reply goes to the
grant; `continue` after a clunk; `stop` after the file's last clunk, when the
file process ends. A clunk's answer is not used: the grant answered the
client's clunk when it sent the job.
""".
-spec run_job(job(), module(), term()) -> {answer, reference(), term()} | continue | stop.
run_job({answer, Alias, Call}, Module, Fs) ->
    {answer, Alias, call(Call, Module, Fs)};
run_job({clunk, Handle}, Module, Fs) ->
    _ = Module:clunk(Handle, Fs),
    continue;
run_job({last_clunk, Handle}, Module, Fs) ->
    _ = Module:clunk(Handle, Fs),
    stop.

call({read, Handle, Offset, Count}, Module, Fs) ->
    case Module:read(Handle, Offset, Count, Fs) of
        {ok, Data} -> {ok, Data};
        Other -> failed(Other)
    end;
call({write, Handle, Offset, Data}, Module, Fs) ->
    case Module:write(Handle, Offset, Data, Fs) of
        {ok, Count, At} -> {ok, Count, At};
        Other -> failed(Other)
    end;
call({readdir, Handle, Offset, Count}, Module, Fs) ->
    case Count div packed_entry(<<>>) of
        0 ->
            {error, einval};
        Fit ->
            case Module:readdir(Handle, Offset, min(Fit, ?DIRENTS_PER_CALL), Fs) of
                {ok, Entries} -> fit_listing(Entries, Count);
                Other -> failed(Other)
            end
    end;
call({fsync, Handle}, Module, Fs) ->
    done(optional(Module, fsync, [Handle, Fs], ok));
call({setattr, Handle, Attr}, Module, Fs) ->
    done(optional(Module, setattr, [{open, Handle}, Attr, Fs], {error, eperm})).

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
Counts `Request`, sent to `Alias`, as in flight until `complete/3` answers it:
the hook for a request whose answer comes from outside the grant's step. A
request admitted while 64 are in flight, flushes waiting on them included,
fails with `emfile`.
""".
-spec defer(reference(), tuple(), grant()) -> grant().
defer(Alias, Request, Grant) ->
    defer(Alias, Request, none, Grant).

defer(Alias, Request, By, #grant{pending = Pending, in_flight = InFlight} = Grant)
  when not is_map_key(Alias, Pending) ->
    Grant#grant{pending = Pending#{Alias => #pending{request = Request, flushes = [], by = By}},
                in_flight = InFlight + 1}.

-doc "Answers a deferred request, then every flush that waited on it.".
-spec complete(reference(), term(), grant()) -> {[effect()], grant()}.
complete(Alias, Reply, #grant{pending = Pending, in_flight = InFlight} = Grant) ->
    {#pending{request = Request, flushes = Flushes}, Rest} = maps:take(Alias, Pending),
    Grant1 = Grant#grant{pending = Rest, in_flight = InFlight - 1 - length(Flushes)},
    {Effects, Grant2} = finish(Alias, Request, Reply, Grant1),
    {Effects ++ [{reply, Flush, ok} || Flush <- lists:reverse(Flushes)], Grant2}.

-doc "What the grant holds, for inspection and tests.".
-spec info(grant()) -> #{fids := non_neg_integer(), owners := non_neg_integer(),
                         files := non_neg_integer(), in_flight := non_neg_integer(),
                         refused := non_neg_integer(), rights := rights()}.
info(#grant{fids = Fids, owners = Owners, files = Files, in_flight = InFlight,
            refused = Refused, rights = Rights}) ->
    #{fids => map_size(Fids), owners => map_size(Owners), files => map_size(Files),
      in_flight => InFlight, refused => Refused, rights => Rights}.

%% The funnel. A frame is admitted only if the grammar accepts it, its owner is
%% a process of the client's domain, and it does not write on a read-only
%% grant. A frame without an alias has no one to answer and is dropped, and so
%% is one whose alias is not the client domain's: the grant answers only its
%% own client, never a third domain on a client's behalf.
decode(Frame, #grant{client = Client, rights = Rights}) ->
    case erx_9p_grammar:decode_request_frame(Frame) of
        error ->
            drop;
        {error, Alias, _} when node(Alias) =/= Client ->
            drop;
        {ok, Alias, _, _} when node(Alias) =/= Client ->
            drop;
        {error, Alias, Posix} ->
            {refuse, Alias, Posix, none};
        {ok, Alias, Owner, _} when node(Owner) =/= Client ->
            {refuse, Alias, einval, none};
        {ok, Alias, Owner, Request} ->
            case Rights =:= rw orelse not erx_9p_grammar:writes(Request) of
                true -> {admit, Alias, Owner, Request};
                false -> {refuse, Alias, erofs, Request}
            end
    end.

%% A remove clunks its fid whatever the outcome, a refusal included.
refused_remove({remove, Fid}, Grant) -> end_fid_if_held(Fid, Grant);
refused_remove(_, Grant) -> Grant.

%% An alias names one request in flight: a request sent to an alias that a
%% deferred request still holds is refused, since the client could not tell
%% the two answers apart. A flush of a request not in flight is answered at
%% once, at the bound too, since it holds nothing; one that must wait for its
%% request takes a slot.
admit(Alias, _, Request, #grant{pending = Pending} = Grant)
  when is_map_key(Alias, Pending) ->
    finish(Alias, Request, {error, einval}, refused_remove(Request, Grant));
admit(Alias, _, {flush, OldTag} = Request, #grant{pending = Pending} = Grant)
  when not is_map_key(OldTag, Pending) ->
    finish(Alias, Request, ok, Grant);
admit(Alias, _, Request, #grant{in_flight = InFlight} = Grant)
  when InFlight >= ?IN_FLIGHT_MAX ->
    finish(Alias, Request, {error, emfile}, refused_remove(Request, Grant));
admit(Alias, _, {flush, OldTag}, #grant{pending = Pending, in_flight = InFlight} = Grant) ->
    #{OldTag := #pending{flushes = Flushes} = Record} = Pending,
    Waiting = Record#pending{flushes = [Alias | Flushes]},
    {[], Grant#grant{pending = Pending#{OldTag := Waiting}, in_flight = InFlight + 1}};
admit(Alias, Owner, Request, Grant) ->
    Directories = erx_9p_grammar:directory_fids(Request),
    case lists:all(fun(Fid) -> directory_or_unheld(Fid, Grant) end, Directories) of
        true ->
            case dispatch(Owner, Request, Grant) of
                {{to_file, Node, Call}, Grant1} -> drain(to_file(Alias, Request, Node, Call, Grant1));
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
        #{Fid := #fid{path = [{_, {Type, _, _}, _} | _]}} -> Type band ?ERX_P9_QTDIR =/= 0;
        #{} -> true
    end.

%% A request on an open file goes to the file process, in flight until its
%% answer arrives through file_answer/4.
to_file(Alias, Request, Node, Call, #grant{files = Files} = Grant) ->
    #{Node := #file{process = Process, tag = Tag}} = Files,
    #grant{effects = Effects} = Grant1 = defer(Alias, Request, Tag, Grant),
    Grant1#grant{effects = [{run, Process, Tag, {answer, Alias, Call}} | Effects]}.

%% Every answer leaves through here, held to its request by the grammar's
%% reply check. An operation is built whole before it is kept: dispatch/3
%% answers its reply with the grant it would leave (Built), and only a reply
%% the check accepts keeps it. A reply the check rejects reaches the client
%% as eio and keeps the grant as it was before the request (Before), its
%% effects included, as a refusal does: a remove still clunks its fid.
%% Every qid the grant records travels in the reply that records it (attach,
%% walk, lcreate), so a callback's malformed answer, a qid included, leaves
%% no fid, open or file process behind. Callers of finish/4 have nothing to
%% undo: a refusal, or an answer from a file process.
finish(Alias, Request, Reply, Grant) ->
    finish(Alias, Request, Reply, Grant, Grant).

finish(Alias, Request, Reply, Built, Before) ->
    {Checked, Grant} = case accepted(Request, Reply) of
                           true -> {Reply, Built};
                           false -> {{error, eio}, refused_remove(Request, Before)}
                       end,
    Grant1 = case Checked of
                 {error, _} -> count_refusal(Grant);
                 _ -> Grant
             end,
    {Effects, Grant2} = drain(Grant1),
    {Effects ++ [{reply, Alias, Checked}], Grant2}.

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

drain(#grant{effects = Effects} = Grant) ->
    {lists:reverse(Effects), Grant#grant{effects = []}}.

%% Each admitted operation, as {Reply, Grant}, or {{to_file, Node, Call}, Grant}
%% for one the file process answers. Every fid a request names is looked
%% up here; a fid the grant does not hold is ebadf.
dispatch(_, {version, Msize, Version}, Grant) ->
    {version(Msize, Version), Grant};
dispatch(Owner, {attach, Fid, Afid, _, Aname, _}, Grant) ->
    attach(Owner, Fid, Afid, Aname, Grant);
dispatch(Owner, {walk, Fid, NewFid, Names}, Grant) ->
    walk(Owner, Fid, NewFid, Names, Grant);
dispatch(_, {getattr, Fid, _}, Grant) ->
    on_node(Fid, Grant, fun(Node, Module, Fs) -> Module:getattr(Node, Fs) end);
dispatch(_, {readlink, Fid}, Grant) ->
    on_node(Fid, Grant, fun(Node, Module, Fs) ->
                                optional(Module, readlink, [Node, Fs], {error, einval})
                        end);
dispatch(_, {statfs, Fid}, Grant) ->
    on_node(Fid, Grant, fun(_, Module, Fs) -> Module:statfs(Fs) end);
dispatch(_, {clunk, Fid}, Grant) ->
    case held(Fid, Grant) of
        true -> {ok, end_fid(Fid, Grant)};
        false -> {{error, ebadf}, Grant}
    end;
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
dispatch(_, {mkdir, Dfid, Name, Mode, _Gid}, Grant) ->
    make(Dfid, Name, {directory, Mode band 8#7777}, Grant);
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
dispatch(_, {remove, Fid}, Grant) ->
    remove(Fid, Grant);
dispatch(_, {renameat, OldDfid, OldName, NewDfid, NewName}, Grant) ->
    case node_of(NewDfid, Grant) of
        {ok, NewDir} ->
            change_on_node(OldDfid, Grant, rename,
                           fun(OldDir) -> [OldDir, OldName, NewDir, NewName] end);
        error ->
            {{error, ebadf}, Grant}
    end;
dispatch(_, {setattr, Fid, Attr}, #grant{fids = Fids} = Grant) ->
    %% A size change through an opened fid is decided by that open's access,
    %% in turn with the file's writes; through an unopened fid, by the node's.
    case Fids of
        #{Fid := #fid{open = {open, Node, Handle}}} -> {{to_file, Node, {setattr, Handle, Attr}}, Grant};
        #{} -> change_on_node(Fid, Grant, setattr, fun(Node) -> [{node, Node}, Attr] end)
    end;
dispatch(_, _, Grant) ->
    %% auth, the extended attributes and the locks are not served.
    {{error, enotsup}, Grant}.

version(Msize, _) when Msize < ?MSIZE_MIN -> {error, einval};
version(Msize, ?VERSION) -> {ok, min(Msize, ?MSIZE_MAX), ?VERSION};
version(Msize, _) -> {ok, min(Msize, ?MSIZE_MAX), <<"unknown">>}.

attach(_, _, Afid, _, Grant) when Afid =/= ?ERX_P9_NOFID ->
    %% auth is not served, so the grant holds no fid an Afid could name.
    {{error, ebadf}, Grant};
attach(Owner, Fid, _, Aname, #grant{module = Module, fs = Fs} = Grant) ->
    case new_fid_admissible(Fid, Grant) of
        ok ->
            case Module:root(Fs) of
                {ok, Aname, Root, Qid} ->
                    {{ok, Qid}, add_fid(Fid, Owner, [{Root, Qid, root}], Grant)};
                {ok, _, _, _} ->
                    {{error, enoent}, Grant};
                Other ->
                    {failed(Other), Grant}
            end;
        {error, _} = Error ->
            {Error, Grant}
    end.

%% A walk names a fid that is not open and a new fid that is not in use, unless
%% it is the same fid. It names the result only when every name was walked; one
%% that stops after the first name lists the qids it walked and changes nothing.
walk(Owner, Fid, NewFid, Names, #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{open = {open, _, _}}} ->
            {{error, einval}, Grant};
        #{Fid := #fid{path = Path}} ->
            Admissible = case NewFid of
                             Fid -> ok;
                             _ -> new_fid_admissible(NewFid, Grant)
                         end,
            case Admissible of
                ok -> walked(Owner, Fid, NewFid, walk_names(Names, Path, [], Grant), Grant);
                {error, _} = Error -> {Error, Grant}
            end;
        #{} ->
            {{error, ebadf}, Grant}
    end.

walked(_, _, _, {stopped, [], Posix}, Grant) ->
    {{error, Posix}, Grant};
walked(_, _, _, {stopped, Qids, _}, Grant) ->
    {{ok, lists:reverse(Qids)}, Grant};
walked(_, Fid, Fid, {done, Path, Qids}, Grant) ->
    {{ok, lists:reverse(Qids)}, set_path(Fid, Path, Grant)};
walked(Owner, _, NewFid, {done, Path, Qids}, Grant) ->
    {{ok, lists:reverse(Qids)}, add_fid(NewFid, Owner, Path, Grant)}.

walk_names([], Path, Qids, _) ->
    {done, Path, Qids};
walk_names([Name | Names], Path, Qids, Grant) ->
    case walk_step(Name, Path, Grant) of
        {ok, [{_, Qid, _} | _] = Path1} -> walk_names(Names, Path1, [Qid | Qids], Grant);
        {error, Posix} -> {stopped, Qids, Posix}
    end.

%% Only a directory is walked from, so a walk that reaches a symbolic link
%% stops at its next name and the callback is never asked to follow one (F2).
%% ".." is the grant's: it stays at the root and otherwise returns to the
%% directory recorded on the way down, even one removed since.
walk_step(_, [{_, {Type, _, _}, _} | _], _) when Type band ?ERX_P9_QTDIR =:= 0 ->
    {error, enotdir};
walk_step(<<"..">>, [_] = Root, _) ->
    {ok, Root};
walk_step(<<"..">>, [_ | Parent], _) ->
    {ok, Parent};
walk_step(Name, [{Dir, _, _} | _] = Path, #grant{module = Module, fs = Fs}) ->
    case Module:walk(Dir, Name, Fs) of
        {ok, Node, Qid} -> {ok, [{Node, Qid, Name} | Path]};
        Other -> failed(Other)
    end.

%% lopen opens an unopened fid in place; a fid at a symbolic link is never
%% opened (eloop), so no open acts on a link the client has not seen.
lopen(Fid, Flags, #grant{fids = Fids, module = Module, fs = Fs} = Grant) ->
    case Fids of
        #{Fid := #fid{open = {open, _, _}}} ->
            {{error, einval}, Grant};
        #{Fid := #fid{path = [{_, {Type, _, _}, _} | _]}} when Type band ?ERX_P9_QTSYMLINK =/= 0 ->
            {{error, eloop}, Grant};
        #{Fid := #fid{path = [{Node, Qid, _} | _]}} ->
            case Module:open(Node, Flags, Fs) of
                {ok, Handle} -> {{ok, Qid, ?IOUNIT}, opened(Fid, Node, Handle, Grant)};
                Other -> {failed(Other), Grant}
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
        #grant{fids = Fids, module = Module, fs = Fs} = Grant) ->
    case Fids of
        #{Fid := #fid{open = {open, _, _}}} ->
            {{error, einval}, Grant};
        #{Fid := #fid{path = [{Dir, _, _} | _] = Path}} ->
            What = {file, Mode band 8#7777, Flags},
            case optional(Module, make, [Dir, Name, What, Fs], {error, eperm}) of
                {ok, Node, Qid, Handle} ->
                    Reply = {ok, Qid, ?IOUNIT},
                    case accepted(Request, Reply) of
                        true ->
                            Grant1 = set_path(Fid, [{Node, Qid, Name} | Path], Grant),
                            {Reply, opened(Fid, Node, Handle, Grant1)};
                        false ->
                            _ = Module:clunk(Handle, Fs),
                            {{error, eio}, Grant}
                    end;
                Other ->
                    {failed(Other), Grant}
            end;
        #{} ->
            {{error, ebadf}, Grant}
    end.

%% A remove unlinks the entry its fid was walked by, only while that entry
%% still names the fid's node (the tree decides, in one step), and clunks the
%% fid whatever the outcome.
remove(Fid, #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{path = [{_, _, root}]}} ->
            {{error, einval}, end_fid(Fid, Grant)};
        #{Fid := #fid{path = [{Node, _, Name}, {Dir, _, _} | _]}} ->
            Reply = change(unlink, [Dir, Name, {node, Node}], Grant),
            {Reply, end_fid(Fid, Grant)};
        #{} ->
            {{error, ebadf}, Grant}
    end.

make(Dfid, Name, What, Grant) ->
    case node_of(Dfid, Grant) of
        {ok, Dir} ->
            case change(make, [Dir, Name, What], Grant) of
                {ok, _Node, Qid} -> {made_reply(What, Qid), Grant};
                {error, _} = Error -> {Error, Grant}
            end;
        error ->
            {{error, ebadf}, Grant}
    end.

made_reply({link, _}, _) -> ok;
made_reply(_, Qid) -> {ok, Qid}.

%% A callback that changes the tree answers ok, or for make the node it made;
%% a tree without the callback keeps nothing of that kind (eperm). The change
%% is the tree's, behind its handle, so the grant holds the same state after.
change_on_node(Fid, Grant, Callback, Arguments) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> {change(Callback, Arguments(Node), Grant), Grant};
        error -> {{error, ebadf}, Grant}
    end.

change(Callback, Arguments, #grant{module = Module, fs = Fs}) ->
    changed(Callback, optional(Module, Callback, Arguments ++ [Fs], {error, eperm})).

changed(make, {ok, Node, Qid}) -> {ok, Node, Qid};
changed(make, Other) -> failed(Other);
changed(_, Answer) -> done(Answer).

on_node(Fid, #grant{module = Module, fs = Fs} = Grant, Read) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> {Read(Node, Module, Fs), Grant};
        error -> {{error, ebadf}, Grant}
    end.

%% An operation of an open file needs an opened fid; an unopened one has no
%% handle to give it (ebadf).
on_open(Fid, #grant{fids = Fids} = Grant, Call) ->
    case Fids of
        #{Fid := #fid{open = {open, Node, Handle}}} -> {{to_file, Node, Call(Handle)}, Grant};
        #{} -> {{error, ebadf}, Grant}
    end.

optional(Module, Callback, Arguments, Absent) ->
    case erlang:function_exported(Module, Callback, length(Arguments)) of
        true -> apply(Module, Callback, Arguments);
        false -> Absent
    end.

node_of(Fid, #grant{fids = Fids}) ->
    case Fids of
        #{Fid := #fid{path = [{Node, _, _} | _]}} -> {ok, Node};
        #{} -> error
    end.

held(Fid, #grant{fids = Fids}) ->
    is_map_key(Fid, Fids).

set_path(Fid, Path, #grant{fids = Fids} = Grant) ->
    #{Fid := #fid{open = none} = Record} = Fids,
    Grant#grant{fids = Fids#{Fid := Record#fid{path = Path}}}.

%% A new fid is refused while its number is alive (einval, as QEMU answers a
%% fid in use) and when the pool is full (emfile).
new_fid_admissible(Fid, #grant{fids = Fids, pool = Pool}) ->
    if
        is_map_key(Fid, Fids) -> {error, einval};
        map_size(Fids) >= Pool -> {error, emfile};
        true -> ok
    end.

%% With set_path/3 and opened/4, the only functions that change the fid
%% table; these two also change the owners
%% and their monitors: an owner is recorded, and monitored, exactly while it
%% owns a fid.
add_fid(Fid, Owner, Path, #grant{fids = Fids, owners = Owners, effects = Effects} = Grant) ->
    Grant1 = Grant#grant{fids = Fids#{Fid => #fid{owner = Owner, path = Path}}},
    case Owners of
        #{Owner := #owner{fids = Owned} = Record} ->
            Grant1#grant{owners = Owners#{Owner := Record#owner{fids = Owned#{Fid => []}}}};
        #{} ->
            Grant1#grant{owners = Owners#{Owner => #owner{monitor = pending, fids = #{Fid => []}}},
                         effects = [{monitor, Owner} | Effects]}
    end.

end_fid(Fid, #grant{fids = Fids, owners = Owners} = Grant) ->
    {#fid{owner = Owner, open = Open}, Fids1} = maps:take(Fid, Fids),
    #{Owner := #owner{monitor = Ref, fids = Owned} = Record} = Owners,
    #grant{effects = Effects} = Grant1 = released(Open, Grant#grant{fids = Fids1}),
    case maps:remove(Fid, Owned) of
        Left when map_size(Left) =:= 0 ->
            Grant1#grant{owners = maps:remove(Owner, Owners),
                         effects = [{demonitor, Ref} | Effects]};
        Left ->
            Grant1#grant{owners = Owners#{Owner := Record#owner{fids = Left}}}
    end.

end_fid_if_held(Fid, Grant) ->
    case held(Fid, Grant) of
        true -> end_fid(Fid, Grant);
        false -> Grant
    end.

%% With file_started/4, the only functions that change the open files: a fid's open starts the
%% file process at the file's first open, and its end sends that process the
%% handle's clunk, the last of which ends the process. The clunk runs after
%% every request already sent to the process, so no request meets a clunked handle.
opened(Fid, Node, Handle, #grant{fids = Fids, files = Files, module = Module, fs = Fs,
                                 effects = Effects} = Grant) ->
    #{Fid := Record} = Fids,
    Grant1 = Grant#grant{fids = Fids#{Fid := Record#fid{open = {open, Node, Handle}}}},
    case Files of
        #{Node := #file{opens = Opens} = File} ->
            Grant1#grant{files = Files#{Node := File#file{opens = Opens + 1}}};
        #{} ->
            Grant1#grant{files = Files#{Node => #file{process = pending, tag = pending, opens = 1}},
                         effects = [{start_file, Node, Module, Fs} | Effects]}
    end.

released(none, Grant) ->
    Grant;
released({open, Node, Handle}, #grant{files = Files, effects = Effects} = Grant) ->
    #{Node := #file{process = Process, tag = Tag, opens = Opens} = File} = Files,
    case Opens of
        1 ->
            Grant#grant{files = maps:remove(Node, Files),
                        effects = [{run, Process, Tag, {last_clunk, Handle}} | Effects]};
        _ ->
            Grant#grant{files = Files#{Node := File#file{opens = Opens - 1}},
                        effects = [{run, Process, Tag, {clunk, Handle}} | Effects]}
    end.
