%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_verity).
-moduledoc """
The hash-checking reader of EROFS images (docs/design-storage.md, Reading
EROFS images, and invariant E1): the one funnel through which the EROFS
reader, `erx_erofs`, reaches an image's blocks.

`open/2` takes the pid of the block service's window on the image and the
image's hash tree, asks the window its length, and returns an opaque handle
that holds the pid and the image's size in blocks. Nothing in the handle's
value stops a module from taking the window out of it; what keeps every
other module on `read/3` is the build check `Erx::ErofsReads`, which
refuses any module but the reader that names this one and keeps the
reader's own calls to the funnel and to modules that reach no state.

`read/3` runs in the calling process, so a slow read delays only its
caller. It checks the request against the image's size and the per-call
limit, sends the window one request per block, all at once, as
`gen_server` calls, each with an alias of its own, so each answer is
matched to its block whatever order they come in, checks that each
answer is exactly the block asked for, and returns each as a binary of
`ERX_EROFS_BLOCK_SIZE` bytes. Every failure, a bad request, a refused,
short or late answer and a window that ended included, answers
`{error, eio}`. A call waits at most `ANSWER_WAIT` for each request; its aliases
end with it, so an answer that arrives later is dropped by the runtime,
and one that arrived as it ended is taken out of the mailbox. Like the reader,
it calls only BIFs, since it runs in whatever process reads a path, the
code server included.

The image's hash tree is not written yet, so the only tree `open/2`
takes is `unchecked`, and the blocks pass through unchecked: the check of
each block against the tree, with the root hash and salt the boot image
records, goes inside `read/3` (see `checked/1`) when the tree is written
after each image.
""".

-export([open/2, read/3]).
-export_type([image/0, tree/0]).

-include("generated/erx_abi.hrl").

%% The window's sectors in one image block.
-define(SECTORS, (?ERX_EROFS_BLOCK_SIZE div ?ERX_VIRTIO_BLK_SECTOR_SIZE)).
%% How long a call waits for each of the window's answers, its deadline this times the
%% requests it sends, since the window answers them one at a time: longer than the
%% window's own wait for the device process (35 s in erx_blk_window), so a window that
%% answers a device that did not is heard first.
-define(ANSWER_WAIT, 40000).

-record(window, {pid :: pid(), blocks :: non_neg_integer()}).

-doc "An open image: its window, which only this module reads through.".
-opaque image() :: #window{}.

-doc """
The image's hash tree. Only `unchecked` exists until the packer writes a
tree after each image; it says so rather than standing for a check.
""".
-type tree() :: unchecked.

-doc """
Opens the image the window `Window` holds, its size the window's length in
whole blocks, or answers `{error, eio}` when the window does not say it.
""".
-spec open(pid(), tree()) -> {ok, image()} | {error, eio}.
open(Window, unchecked) when is_pid(Window) ->
    case call(Window, [info]) of
        {ok, [{ok, #{sectors := Sectors}}]} when is_integer(Sectors), Sectors >= 0 ->
            {ok, #window{pid = Window, blocks = Sectors div ?SECTORS}};
        _ ->
            {error, eio}
    end;
open(_, _) ->
    {error, eio}.

-doc """
Returns `Count` blocks of the image from block `Block`, 1 to
`ERX_VERITY_READ_BLOCKS_MAX` of them, each a binary of
`ERX_EROFS_BLOCK_SIZE` bytes, or `{error, eio}`.
""".
-spec read(image(), non_neg_integer(), pos_integer()) -> {ok, [binary()]} | {error, eio}.
read(#window{pid = Pid, blocks = Blocks}, Block, Count)
  when is_integer(Block), Block >= 0, is_integer(Count),
       Count >= 1, Count =< ?ERX_VERITY_READ_BLOCKS_MAX, Block + Count =< Blocks ->
    Requests = [{read, (Block + Index) * ?SECTORS, ?SECTORS} || Index <- indexes(Count - 1, [])],
    case call(Pid, Requests) of
        {ok, Answers} -> blocks(Answers, []);
        error -> {error, eio}
    end;
read(_, _, _) ->
    {error, eio}.

%% The window's answers as blocks, each to match the image's hash tree before it is
%% returned. The check goes in checked/1: each block's SHA-256, salted, against its leaf
%% in the tree, the tree's blocks read and checked up to the root hash; a mismatch answers
%% {error, eio}. Until then the blocks pass through unchecked.
blocks([], Checked) ->
    {ok, reverse(Checked, [])};
blocks([{ok, Block} | Answers], Checked)
  when is_binary(Block), byte_size(Block) =:= ?ERX_EROFS_BLOCK_SIZE ->
    blocks(Answers, [checked(Block) | Checked]);
blocks(_, _) ->
    {error, eio}.

checked(Block) ->
    Block.

%% The window's answers to Requests, in order, or error once one is missing: the window
%% ended or did not answer by the deadline. Each request is a gen_server call made by
%% hand, since gen_server is not preloaded: {'$gen_call', {Pid, Tag}, Request}, whose
%% Tag [alias | Alias] is gen's form for a reply sent to the alias Alias. Each request has
%% its own reply alias, so an answer can only be its own request's; the monitor, which
%% ends with the call, sees the window end.
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
    {ok, reverse(Answers, [])};
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

%% lists:seq/2, lists:zip/2 and lists:reverse/2, which this module cannot call (lists is
%% not preloaded): 0 to Last in order, two lists paired, and a list reversed onto a tail.
indexes(Last, Indexes) when Last < 0 -> Indexes;
indexes(Last, Indexes) -> indexes(Last - 1, [Last | Indexes]).

zip([A | As], [B | Bs]) -> [{A, B} | zip(As, Bs)];
zip([], []) -> [].

reverse([], Tail) -> Tail;
reverse([Head | List], Tail) -> reverse(List, [Head | Tail]).
