%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's one write path (docs/design-storage.md, "The block driver", and
%% invariant U4): every write the driver makes to the medium is a request this module
%% builds and posts. tools/lib/erx/block_write_path.rb holds the rule as a build check: no
%% module but this one names the request type ERX_VIRTIO_BLK_T_OUT, and no other module
%% lays out a header with a type of its caller's choosing. post/6 does not apply U4's trial
%% rule, which refuses every write but the boot-selection record's while a trial boots:
%% TODO.md holds that gap.

-module(erx_blk_write).

-export([segments/3, post/6]).

-include("generated/erx_abi.hrl").

%% A write of Data, a whole number of sectors, from Sector: the header and the sectors out,
%% the status in. Data that is not a binary of one to max_sectors() whole sectors is
%% bad_count, and sectors past Capacity are out_of_range.
-spec segments(term(), term(), non_neg_integer()) ->
          {ok, [erx_device:segment()]} | {error, out_of_range | bad_count}.
segments(Sector, Data, Capacity) when is_binary(Data),
                                      byte_size(Data) rem ?ERX_VIRTIO_BLK_SECTOR_SIZE =:= 0 ->
    Count = byte_size(Data) div ?ERX_VIRTIO_BLK_SECTOR_SIZE,
    case erx_blk_request:range(Sector, Count, Capacity) of
        ok ->
            {ok, [{out, <<?ERX_VIRTIO_BLK_T_OUT:32/little, 0:32/little, Sector:64/little>>}, {out, Data}, {in, 1}]};
        Refused ->
            Refused
    end;
segments(_Sector, _Data, _Capacity) ->
    {error, bad_count}.

%% Posts the write under Tag on the device's queue. A refused write touches nothing.
-spec post(erx_device:device(), erx_device:queue(), non_neg_integer(), term(), term(),
           non_neg_integer()) -> ok | {error, out_of_range | bad_count | full | broken}.
post(Dev, Queue, Tag, Sector, Data, Capacity) ->
    case segments(Sector, Data, Capacity) of
        {ok, Segments} -> erx_device:post(Dev, Queue, Tag, Segments);
        Refused -> Refused
    end.
