%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_verity).
-moduledoc """
The hash-checking reader of EROFS images (docs/design-storage.md, Reading
EROFS images, and invariant E1): the one funnel through which the EROFS
reader, `erx_erofs`, reaches an image's blocks.

`open/2` takes the pid of the block service's window on the image and the
image's layout, `erx_verity_tree:layout()`: the image's offset and length
and its dm-verity hash tree's offset and length in the window, the tree's
salt and its root hash. It asks the window its length, refuses a layout
with another key, whose image is empty, does not start on a block or is
not whole blocks, whose
tree does not start on a block at or past the image's end, is not as long
as `erx_verity_tree` gives for the image, or does not fit the window, and
returns an opaque handle that holds the pid and the layout, a record named
for this module.

`open_file/3` opens an image that lies in a file rather than a window: it
takes a file server's grant (`erx_file_remote:grant()`), a fid on it open
for reading, and the layout, which it checks as `open/2` does against the
file's length, which a `getattr` gives. The image's blocks are then the
file's 4 KiB blocks, read by positioned reads on the fid. It is the EROFS
file mount's open: `erx_ns`'s process walks the file the app's record
names to a fid it owns and opens it with the record's layout, so its
handle always has a tree; there is no unchecked file.

Nothing in the handle's value stops a module from taking the window or
the fid out of it; what keeps every other module off them is the build
check `Erx::ErofsReads`, which refuses every naming of this module outside
it but these:

* each mounter's one open: `open/2` in `erx_storage_system`, on the
  `system` window with its layout, and `open_file/3` in `erx_ns`, for the
  app mount;
* the call `read/3` and the type `image()` in the reader, which mounts the
  handle they open, and whose other calls the check keeps to modules that
  reach no state.

`read/3` runs in the calling process, so a slow read delays only its
caller. It checks the request against the image's size and the per-call
limit, and asks the source for each block it needs, all at once: the data
blocks asked for and, on each level of the tree, the blocks that hold their
hashes. A window is sent a `gen_server` call for each block with an alias
of its own, so each answer is matched to its block whatever order they
come in; a file is sent one 9P exchange of positioned reads, whose answers
come in the order of the reads.
Each answer must be a whole block, its block the one its alias names; then it checks the
tree level by level, top first, in `check/2`: the top block against the
root hash, each lower block against its hash in the level above, and each
data block against its hash in the lowest level, every hash the SHA-256 of
the salt and the block. It returns the data blocks only if every one
matched, each a binary of `ERX_EROFS_BLOCK_SIZE` bytes. Every failure, a
bad request, a refused, short or late answer, a window or file server that
ended and a block that does not match its hash included, answers
`{error, eio}`. A file's exchange waits as `erx_file_remote` waits, until
the answers or the server's end, with no deadline of its own. A call to a
window waits at most `ANSWER_WAIT` for each request; its aliases end with
it, so an answer that arrives later is dropped by the runtime, and one
that arrived as it ended is taken out of the mailbox. Like the reader, it
calls only BIFs and preloaded modules, the SHA-256 built-ins of
`erx_bytes` and `erx_verity_tree` and the 9P client `erx_file_remote`, since it runs in whatever process reads
a path, the code server included.

The tree `unchecked` opens a window that has no layout, which no module of
a release does: only the tests mount images that way, whose blocks pass
through unchecked.
""".

-export([open/2, open_file/3, read/3]).
-export_type([image/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).
%% The window's sectors in one image block.
-define(SECTORS, (?BLOCK div ?ERX_VIRTIO_BLK_SECTOR_SIZE)).
%% The hashes one tree block holds.
-define(HASHES, (?BLOCK div ?ERX_VERITY_HASH_SIZE)).
%% How long a call waits for each of the window's answers, its deadline this times the
%% requests it sends, since the window answers them one at a time: longer than the
%% window's own wait for the device process (35 s in erx_blk_window), so a window that
%% answers a device that did not is heard first.
-define(ANSWER_WAIT, 40000).

%% An open image: its source, the source block that is the image's block 0, the image's
%% size in blocks, and how its blocks are checked: unchecked, or against the tree's salt
%% (kept as the SHA-256 state after it, made once at open and continued by every block's
%% hash, since a state is a value), its root hash and the window block where each level
%% of the tree starts, the lowest first.
-record(erx_verity, {source :: source(),
                 base :: non_neg_integer(),
                 blocks :: non_neg_integer(),
                 tree :: unchecked | checking()}).

%% Where an image's blocks come from: the block service's window on it, or a fid open
%% for reading on a file server's grant, whose blocks are the file's 4 KiB blocks.
-type source() :: {window, pid()} | {file, {pid(), binary(), ro | rw | rx}, non_neg_integer()}.

%% How an open image's blocks are checked against its tree.
-type checking() :: #{salted := erx_bytes:sha256_state(), root_hash := <<_:256>>, starts := [non_neg_integer()]}.

-doc "An open image: its window or file, which only this module reads through.".
-opaque image() :: #erx_verity{}.

-doc """
How the image's blocks are checked: against the tree a layout places, or
`unchecked`, for a window that has no layout.
""".
-type tree() :: erx_verity_tree:layout() | unchecked.

%% Blocks First to Last of one level of a read, counted from the level's block 0, which
%% is window block Base. The image's own blocks are the level below the tree's lowest.
%% A read is a list of spans, the data blocks first and then the blocks on their path
%% through the tree, the lowest level first; read/3 asks the window for the blocks in that
%% order, and levels/3 takes the answers back by the same list.
-type span() :: {Base :: non_neg_integer(), First :: non_neg_integer(), Last :: non_neg_integer()}.

%% A level read: its blocks from index First, as a span named them.
-type level() :: {First :: non_neg_integer(), Blocks :: [binary()]}.

-doc """
Opens the image the window `Window` holds under `Tree`, or answers
`{error, eio}` when the window does not say its length or the layout does
not fit it.
""".
-spec open(pid(), tree()) -> {ok, image()} | {error, eio}.
open(Window, Tree) when is_pid(Window) ->
    case call(Window, [info]) of
        {ok, [{ok, #{sectors := Sectors}}]} when is_integer(Sectors), Sectors >= 0 ->
            opened({window, Window}, Sectors div ?SECTORS, Tree);
        _ ->
            {error, eio}
    end;
open(_, _) ->
    {error, eio}.

opened(Source, WindowBlocks, unchecked) ->
    {ok, #erx_verity{source = Source, base = 0, blocks = WindowBlocks, tree = unchecked}};
opened(Source, WindowBlocks, #{image_offset := Offset, image_length := Length, tree_offset := TreeOffset,
                            tree_length := TreeLength, salt := Salt, root_hash := <<_:256>> = Root} = Layout)
  when map_size(Layout) =:= 6, is_integer(Offset), Offset >= 0, Offset rem ?BLOCK =:= 0,
       is_integer(Length), Length > 0, Length rem ?BLOCK =:= 0,
       is_integer(TreeOffset), TreeOffset >= Offset + Length, TreeOffset rem ?BLOCK =:= 0,
       TreeOffset div ?BLOCK =< WindowBlocks,
       is_integer(TreeLength), is_binary(Salt) ->
    Blocks = Length div ?BLOCK,
    TreeBlocks = erx_verity_tree:blocks(Blocks),
    case TreeLength =:= TreeBlocks * ?BLOCK andalso TreeOffset div ?BLOCK + TreeBlocks =< WindowBlocks of
        true ->
            Lengths = erx_verity_tree:levels(Blocks),
            Starts = starts(lists:reverse(Lengths, []), TreeOffset div ?BLOCK, []),
            {ok, #erx_verity{source = Source, base = Offset div ?BLOCK, blocks = Blocks,
                         tree = #{salted => erx_bytes:sha256_update(erx_bytes:sha256_init(), Salt),
                                  root_hash => Root, starts => Starts}}};
        false ->
            {error, eio}
    end;
opened(_, _, _) ->
    {error, eio}.

-doc """
Opens the image the file `Fid` holds under `Layout`, a fid open for reading
on the grant `Grant` (`erx_file_remote:grant()`): the EROFS file mount's,
which `erx_ns`'s process walked and owns. The file's length, by a
`getattr`, bounds the layout as a window's does; every block is checked, so
there is no unchecked file. `{error, eio}` when the server does not say the
length or the layout does not fit the file.
""".
-spec open_file({pid(), binary(), ro | rw | rx}, non_neg_integer(), erx_verity_tree:layout()) ->
          {ok, image()} | {error, eio}.
open_file({Server, _, _} = Grant, Fid, Layout) when is_pid(Server), is_integer(Fid), is_map(Layout) ->
    case erx_file_remote:exchange(Grant, [{getattr, Fid, ?ERX_P9_GETATTR_MASK_SIZE}]) of
        [{ok, #{size := Size}}] when is_integer(Size), Size >= 0 ->
            opened({file, Grant, Fid}, Size div ?BLOCK, Layout);
        _ ->
            {error, eio}
    end;
open_file(_, _, _) ->
    {error, eio}.

%% The window block where each level starts, the lowest first, from the length of each
%% level in blocks, top first, as they lie from the tree's first block At.
starts([], _At, Starts) -> Starts;
starts([Length | Lengths], At, Starts) -> starts(Lengths, At + Length, [At | Starts]).

-doc """
Returns `Count` blocks of the image from block `Block`, 1 to
`ERX_VERITY_READ_BLOCKS_MAX` of them, each a binary of
`ERX_EROFS_BLOCK_SIZE` bytes that matched the image's tree, or
`{error, eio}`.
""".
-spec read(image(), non_neg_integer(), pos_integer()) -> {ok, [binary()]} | {error, eio}.
read(#erx_verity{source = Source, base = Base, blocks = Blocks, tree = Tree}, Block, Count)
  when is_integer(Block), Block >= 0, is_integer(Count),
       Count >= 1, Count =< ?ERX_VERITY_READ_BLOCKS_MAX, Block + Count =< Blocks ->
    Last = Block + Count - 1,
    Spans = [{Base, Block, Last} | path(Tree, Block div ?HASHES, Last div ?HASHES)],
    case fetched(Source, [At || Span <- Spans, At <- window_blocks(Span)]) of
        {ok, Answers} -> checked(Tree, Spans, Answers);
        error -> {error, eio}
    end;
read(_, _, _) ->
    {error, eio}.

%% The answers for the source's blocks Ats, in order, each {ok, Block} when it came: a
%% window is asked by sectors, a file by positioned reads on its fid, all at once.
fetched({window, Pid}, Ats) ->
    call(Pid, [{read, At * ?SECTORS, ?SECTORS} || At <- Ats]);
fetched({file, Grant, Fid}, Ats) ->
    {ok, erx_file_remote:exchange(Grant, [{read, Fid, At * ?BLOCK, ?BLOCK} || At <- Ats])}.

%% The window blocks a span names, in order.
-spec window_blocks(span()) -> [non_neg_integer()].
window_blocks({Base, First, Last}) -> indexes(Base + Last, Base + First, []).

%% The spans of the tree blocks that hold the hashes of blocks First to Last of the level
%% below, on each level, the lowest first. An unchecked image needs none.
-spec path(unchecked | checking(), non_neg_integer(), non_neg_integer()) -> [span()].
path(unchecked, _First, _Last) ->
    [];
path(#{starts := Starts}, First, Last) ->
    path(Starts, First, Last, []).

path([], _First, _Last, Spans) ->
    lists:reverse(Spans, []);
path([Start | Starts], First, Last, Spans) ->
    path(Starts, First div ?HASHES, Last div ?HASHES, [{Start, First, Last} | Spans]).

%% The data blocks, once every answer is a whole block and, over a tree, every block
%% matched its hash.
-spec checked(unchecked | checking(), [span(), ...], [term()]) -> {ok, [binary()]} | {error, eio}.
checked(Tree, Spans, Answers) ->
    case whole(Answers, []) of
        {ok, Read} ->
            case {Tree, levels(Spans, Read, [])} of
                {unchecked, [{_, Data}]} -> {ok, Data};
                {#{}, Levels} -> check(Tree, Levels)
            end;
        error ->
            {error, eio}
    end.

whole([], Blocks) ->
    {ok, lists:reverse(Blocks, [])};
whole([{ok, Block} | Answers], Blocks) when is_binary(Block), byte_size(Block) =:= ?BLOCK ->
    whole(Answers, [Block | Blocks]);
whole(_, _) ->
    error.

%% The levels read, one for each span, from the blocks read in the spans' order: the
%% reverse of that order, so the top level first and the data blocks last.
-spec levels([span()], [binary()], [level()]) -> [level()].
levels([], [], Levels) ->
    Levels;
levels([{_Base, First, Last} | Spans], Read, Levels) ->
    {Blocks, Rest} = split(Last - First + 1, Read, []),
    levels(Spans, Rest, [{First, Blocks} | Levels]).

%% The pure check of the levels read, the top first and the data blocks last: each level
%% against the level above it, the root hash standing above the top as a level of one
%% block holding one hash. It returns the last level's blocks, the data, when every block
%% matched.
-spec check(checking(), [level(), ...]) -> {ok, [binary()]} | {error, eio}.
check(#{salted := Salted, root_hash := Root}, [_ | _] = Levels) ->
    check(Salted, {0, [Root]}, Levels).

check(_Salted, {_First, Checked}, []) ->
    {ok, Checked};
check(Salted, Parent, [Level | Levels]) ->
    case matches(Salted, Parent, Level) of
        true -> check(Salted, Level, Levels);
        false -> {error, eio}
    end.

%% Whether each block of a level, index First onwards, hashes to its slot in the parent
%% level: block I's hash is hash I of the parent level, its parent blocks read from index
%% ParentFirst, HASHES hashes in each (the root, at index 0, is the one hash). A block
%% whose slot lies outside the parent blocks read does not match.
matches(Salted, {ParentFirst, Parents}, {First, Blocks}) ->
    Hashes = iolist_to_binary(Parents),
    SlotOffset = (First - ParentFirst * ?HASHES) * ?ERX_VERITY_HASH_SIZE,
    SlotOffset >= 0 andalso SlotOffset =< byte_size(Hashes)
        andalso hashed(Salted, binary:part(Hashes, SlotOffset, byte_size(Hashes) - SlotOffset), Blocks).

%% Whether each block hashes to the next hash of Hashes.
hashed(_Salted, _Hashes, []) ->
    true;
hashed(Salted, <<Hash:?ERX_VERITY_HASH_SIZE/binary, Hashes/binary>>, [Block | Blocks]) ->
    Hash =:= hash(Salted, Block) andalso hashed(Salted, Hashes, Blocks);
hashed(_Salted, _Hashes, _Blocks) ->
    false.

hash(Salted, Block) ->
    erx_bytes:sha256_final(erx_bytes:sha256_update(Salted, Block)).

%% The window's answers to Requests, in order, or error once one is missing: the window
%% ended or did not answer by the deadline. Each request is a gen_server call made by
%% hand, since gen_server is not preloaded: {'$gen_call', {Pid, Tag}, Request}, whose
%% Tag [alias | Alias] is gen's form for a reply sent to the alias Alias. Each request has
%% its own reply alias, so an answer can only be its own request's; the monitor, which
%% ends with the call, sees the window end.
-dialyzer({no_improper_lists, call/2}).
call(Pid, Requests) ->
    Monitor = monitor(process, Pid),
    Tags = [[alias | alias([reply])] || _ <- Requests],
    _ = [Pid ! {'$gen_call', {self(), Tag}, Request} || {Tag, Request} <- zip(Tags, Requests)],
    Deadline = erlang:monotonic_time(millisecond) + ?ANSWER_WAIT * length(Requests),
    Answers = answers(Monitor, Tags, Deadline, []),
    demonitor(Monitor, [flush]),
    _ = [unalias(Alias) || [alias | Alias] <- Tags],
    drop(Tags),
    Answers.

answers(_, [], _, Answers) ->
    {ok, lists:reverse(Answers, [])};
answers(Monitor, [Tag | Tags], Deadline, Answers) ->
    receive
        {Tag, Answer} -> answers(Monitor, Tags, Deadline, [Answer | Answers]);
        {'DOWN', Monitor, process, _, _} -> error
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error
    end.

%% An answer that arrived after its call gave up, before its alias ended.
drop(Tags) ->
    _ = [receive {Tag, _} -> ok after 0 -> ok end || Tag <- Tags],
    ok.

%% lists:seq/2, lists:split/2 and lists:zip/2, which this module cannot call (lists is not
%% preloaded; its reverse/2 is a BIF): From to To in order onto a tail, a list's first N
%% elements and the rest, and two lists paired. As indexes/3 makes no index of an empty
%% range, split/3 takes no element for a count below one.
indexes(To, From, Indexes) when To < From -> Indexes;
indexes(To, From, Indexes) -> indexes(To - 1, From, [To | Indexes]).

split(N, List, Taken) when N =< 0 -> {lists:reverse(Taken, []), List};
split(N, [Head | List], Taken) -> split(N - 1, List, [Head | Taken]).

zip([A | As], [B | Bs]) -> [{A, B} | zip(As, Bs)];
zip([], []) -> [].

