%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The windows on the booted slot's EROFS images (docs/design-storage.md, "Data model";
%% docs/todo-system-partition.md, deletions): the block service's pure core for them, as
%% erx_blk_table is for the partition table. erx_blk_service hands it the booted
%% slot and the release's manifest, and starts a window for each window it returns.
%%
%% The slot is erx_blk_table:booted/1's, read from `-erx_record boot VALUE SLOT`. A boot
%% whose value is unknown, and a runtime the root gave no such words (the hosted entry),
%% has no slot, so it serves no image window: a window on an image lies only inside the
%% slot the boot value names.
%%
%% windows/2 reads the manifest with the generated reader, erx_manifest, in three steps:
%%   1. it picks the system domain's read-only verified_image windows, each naming an image;
%%   2. it reads each such image: its name, format, data_bytes and extents;
%%   3. place/2 turns each image into a window of role {image, Name} in the slot, or a
%%      refusal.
%% An extent's slot_offset and length are bytes from the start of the slot's system
%% partition, which holds the slot's images (abi/medium.txt). Phase 1 serves an
%% image of format erofs_unchecked in one extent, whose window is its data alone
%% (docs/design-abi.md). Each other image is refused by name with why, and the rest are
%% served: format for another format, extent_count for more than one extent,
%% extent_bounds for an extent that is not whole sectors inside that partition, and length for
%% one that is not data_bytes long. Phase 1 has one block device, the one the service
%% drives; the packer's check (docs/design-fiasco.md, "The Phase 1 manifest check") puts
%% every image and its window on it, so the device fields are not read.
%%
%% A refusal names an image by its manifest name, which the reader checked as an
%% identifier, and otherwise holds only this module's atoms.

-module(erx_blk_image).

-export([windows/2, place/2]).
-export_type([image/0, reason/0]).

-include("generated/erx_abi.hrl").

%% An image as place/2 takes it: its record's name, format and data_bytes, and its extents
%% as {SlotOffset, Length}, each in bytes.
-type image() :: #{name := binary(), format := non_neg_integer(), data_bytes := non_neg_integer(),
                   extents := [{non_neg_integer(), non_neg_integer()}]}.
-type reason() :: {binary(), format | extent_count | extent_bounds | length}.

%% The image windows of Slot that the manifest Manifest gives the system domain, and why
%% each other image it names is not served; manifest when the reader refuses the manifest.
-spec windows(binary(), erx_blk_table:slot() | none) -> {ok, [erx_blk_table:window()], [reason()]} | {error, manifest}.
windows(_Manifest, none) ->
    {ok, [], []};
windows(Manifest, Slot) ->
    maybe
        {ok, View} ?= erx_manifest:open(Manifest),
        {ok, Indices} ?= erx_manifest:fold(View, windows, fun image_window/2, []),
        {ok, Images} ?= images(View, lists:usort(Indices), []),
        Placed = [place(Image, Slot) || Image <- Images],
        {ok, [Window || {ok, Window} <- Placed], [Reason || {error, Reason} <- Placed]}
    else
        {error, _} -> {error, manifest}
    end.

%% The window of Image in Slot, or why it has none.
-spec place(image(), erx_blk_table:slot()) -> {ok, erx_blk_table:window()} | {error, reason()}.
place(#{name := Name, format := ?ERX_MF_IMAGE_FORMAT_EROFS_UNCHECKED, data_bytes := Bytes,
        extents := [{Offset, Length}]}, Slot) ->
    Sector = ?ERX_VIRTIO_BLK_SECTOR_SIZE,
    {Start, Sectors} = erx_blk_table:system_partition(Slot),
    case Offset rem Sector =:= 0 andalso Length rem Sector =:= 0 andalso Length > 0
         andalso Offset + Length =< Sectors * Sector of
        false -> {error, {Name, extent_bounds}};
        true when Length =/= Bytes -> {error, {Name, length}};
        true -> {ok, {{image, Name}, Start + Offset div Sector, Length div Sector}}
    end;
place(#{name := Name, format := ?ERX_MF_IMAGE_FORMAT_EROFS_UNCHECKED}, _Slot) ->
    {error, {Name, extent_count}};
place(#{name := Name}, _Slot) ->
    {error, {Name, format}}.

%% The image a window names when it is the system domain's read-only verified_image
%% window; the reader's rules and the packer's refuse a writable one, so none is served.
image_window(#{holder := ?ERX_MF_NONE, role := ?ERX_MF_WINDOW_ROLE_VERIFIED_IMAGE,
               rights := ?ERX_MF_WINDOW_RIGHTS_READ, image := Image}, Indices)
  when Image =/= ?ERX_MF_NONE ->
    [Image | Indices];
image_window(_Window, Indices) ->
    Indices.

%% The images at Indices of the images table, as place/2 takes them, each with the
%% extents table's rows its extents span names, which the reader gives.
images(_View, [], Images) ->
    {ok, lists:reverse(Images)};
images(View, [Index | Rest], Images) ->
    maybe
        {ok, #{name := NameRef, format := Format, data_bytes := Bytes}} ?= erx_manifest:fetch(View, images, Index),
        {ok, Name} ?= erx_manifest:string(View, NameRef),
        {ok, Rows} ?= erx_manifest:span(View, images, Index, extents),
        Extents = [{Offset, Length} || #{slot_offset := Offset, length := Length} <- Rows],
        Image = #{name => Name, format => Format, data_bytes => Bytes, extents => Extents},
        images(View, Rest, [Image | Images])
    end.
