%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_verity).
-moduledoc """
The hash-checking reader of EROFS images (docs/design-storage.md, Reading
EROFS images, and invariant E1): the one funnel through which the EROFS
reader, `erx_erofs`, reaches an image's blocks.

`open/2` takes what reads the image's blocks, here a function standing in
for the block service's window on the image, and the image's size in
blocks, and returns an opaque handle that holds them. Nothing in the
handle's value stops a module from taking the window out of it; what keeps
every other module on `read/3` is the build check `Erx::ErofsReads`, which
refuses any module but the reader that names this one and keeps the
reader's own calls to the funnel and to modules that reach no state.

`read/3` runs in the calling process, so a slow read delays only its
caller. It checks the request against the image's size and the per-call
limit, reads the blocks, checks that exactly the blocks asked for came
back, and returns each as a binary of `ERX_EROFS_BLOCK_SIZE` bytes. Every
failure, a bad request, a failed or short answer and an exception of the
window included, answers `{error, eio}`. Like the reader, it calls only
BIFs, since it runs in whatever process reads a path, the code server
included.

The blocks pass through unchecked: the check of each block against the
image's hash tree, with the root hash and salt the boot image records, is
added inside `read/3` (see `checked/1`) when the tree is written after
each image.
""".

-export([open/2, read/3]).
-export_type([image/0, read_blocks/0]).

-include("generated/erx_abi.hrl").

-doc """
Reads `Count` blocks from block `First` of the image and returns them
joined, or fails. Its result is checked, never trusted.
""".
-type read_blocks() :: fun((First :: non_neg_integer(), Count :: pos_integer()) ->
                               {ok, binary()} | {error, term()}).

-record(window, {read :: read_blocks(), blocks :: non_neg_integer()}).

-doc "An open image: its window, which only this module reads through.".
-opaque image() :: #window{}.

-doc "Opens an image of `Blocks` blocks read through `Read`.".
-spec open(read_blocks(), non_neg_integer()) -> {ok, image()}.
open(Read, Blocks) when is_function(Read, 2), is_integer(Blocks), Blocks >= 0 ->
    {ok, #window{read = Read, blocks = Blocks}}.

-doc """
Returns `Count` blocks of the image from block `Block`, 1 to
`ERX_VERITY_READ_BLOCKS_MAX` of them, each a binary of
`ERX_EROFS_BLOCK_SIZE` bytes, or `{error, eio}`.
""".
-spec read(image(), non_neg_integer(), pos_integer()) -> {ok, [binary()]} | {error, eio}.
read(#window{read = Read, blocks = Blocks}, Block, Count)
  when is_integer(Block), Block >= 0, is_integer(Count),
       Count >= 1, Count =< ?ERX_VERITY_READ_BLOCKS_MAX, Block + Count =< Blocks ->
    try Read(Block, Count) of
        {ok, Bytes} when is_binary(Bytes), byte_size(Bytes) =:= Count * ?ERX_EROFS_BLOCK_SIZE ->
            checked(Bytes);
        _ ->
            {error, eio}
    catch
        _:_ -> {error, eio}
    end;
read(_, _, _) ->
    {error, eio}.

%% Splits the window's bytes into blocks, each of which is to match the
%% image's hash tree before it is returned. The check goes here: each
%% block's SHA-256, salted, against its leaf in the tree, the tree's blocks
%% read and checked up to the root hash; a mismatch answers {error, eio}.
%% Until then the blocks pass through unchecked.
checked(Bytes) ->
    {ok, [Block || <<Block:?ERX_EROFS_BLOCK_SIZE/binary>> <= Bytes]}.
