%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's one write path (docs/design-storage.md, "The block driver", and
%% invariant U4), held by construction: this module is the only one that posts a request
%% to the device, and it builds every request it posts, the header's request type
%% included. read/6 posts a read, whose type is ERX_VIRTIO_BLK_T_IN; write/6 posts a write,
%% whose type is ERX_VIRTIO_BLK_T_OUT, and is the only function that builds one. Nothing a
%% caller passes chooses the type, so no other module can make the device write.
%% tools/lib/erx/device_posters.rb holds the rule as a build check: no module but this one
%% calls erx_device:post/4.
%%
%% read_segments/3 and write_segments/3 are pure, so the requests are tested and fuzzed on
%% the host (test/erlang/erx_blk_request_tests.erl and erx_blk_request_fuzz.erl). write/6
%% does not apply U4's trial rule, which refuses every write but the boot-selection
%% record's while a trial boots: TODO.md holds that gap.

-module(erx_blk_write).

-export([read_segments/3, write_segments/3, read/6, write/6]).

-include("generated/erx_abi.hrl").

%% The status byte the device writes last, after the sectors.
-define(STATUS_BYTES, 1).

%% A read of Count sectors from Sector: the header out, the sectors and the status in.
-spec read_segments(term(), term(), non_neg_integer()) ->
          {ok, [erx_device:segment()]} | {error, out_of_range | bad_count}.
read_segments(Sector, Count, Capacity) ->
    case erx_blk_request:range(Sector, Count, Capacity) of
        ok ->
            {ok, [{out, header(?ERX_VIRTIO_BLK_T_IN, Sector)},
                  {in, Count * ?ERX_VIRTIO_BLK_SECTOR_SIZE},
                  {in, ?STATUS_BYTES}]};
        Refused ->
            Refused
    end.

%% A write of Data, a whole number of sectors, from Sector: the header and the sectors out,
%% the status in. Data that is not a binary of one to max_sectors() whole sectors is
%% bad_count, and sectors past Capacity are out_of_range.
-spec write_segments(term(), term(), non_neg_integer()) ->
          {ok, [erx_device:segment()]} | {error, out_of_range | bad_count}.
write_segments(Sector, Data, Capacity) when is_binary(Data),
                                            byte_size(Data) rem ?ERX_VIRTIO_BLK_SECTOR_SIZE =:= 0 ->
    Count = byte_size(Data) div ?ERX_VIRTIO_BLK_SECTOR_SIZE,
    case erx_blk_request:range(Sector, Count, Capacity) of
        ok ->
            {ok, [{out, header(?ERX_VIRTIO_BLK_T_OUT, Sector)}, {out, Data}, {in, ?STATUS_BYTES}]};
        Refused ->
            Refused
    end;
write_segments(_Sector, _Data, _Capacity) ->
    {error, bad_count}.

%% Posts a read of Count sectors from Sector under Tag on the device's queue. A refused
%% read touches nothing.
-spec read(erx_device:device(), erx_device:queue(), non_neg_integer(), term(), term(),
           non_neg_integer()) -> ok | {error, out_of_range | bad_count | full | broken}.
read(Dev, Queue, Tag, Sector, Count, Capacity) ->
    post(Dev, Queue, Tag, read_segments(Sector, Count, Capacity)).

%% Posts a write of Data from Sector under Tag on the device's queue. A refused write
%% touches nothing.
-spec write(erx_device:device(), erx_device:queue(), non_neg_integer(), term(), term(),
            non_neg_integer()) -> ok | {error, out_of_range | bad_count | full | broken}.
write(Dev, Queue, Tag, Sector, Data, Capacity) ->
    post(Dev, Queue, Tag, write_segments(Sector, Data, Capacity)).

post(Dev, Queue, Tag, {ok, Segments}) -> erx_device:post(Dev, Queue, Tag, Segments);
post(_Dev, _Queue, _Tag, Refused) -> Refused.

%% A request's header, laid out as abi/formats/virtio.txt's erx_virtio_blk_req_header:
%% type, a reserved word and the first sector.
header(Type, Sector) ->
    <<Type:32/little, 0:32/little, Sector:64/little>>.
