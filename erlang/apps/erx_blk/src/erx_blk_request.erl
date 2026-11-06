%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's pure core (docs/design-storage.md, "The block driver"): what the
%% driver checks before it touches the device and what it makes of the bytes the device
%% wrote. Nothing here calls the device NIF, so the module builds and runs anywhere and its
%% decisions are tested and fuzzed on the host (test/erlang/erx_blk_request_tests.erl and
%% erx_blk_request_fuzz.erl).
%%
%% A request is virtio's (section 5.2.6 of the specification): a 16-byte header the device
%% reads, then the sectors it reads or writes, then one status byte it writes. Its segments
%% are built and posted by erx_blk_write, the one module that posts and so the driver's one
%% write path, with range/3.
%%
%% Everything the device wrote is untrusted. decode/2 takes the bytes erx_device:complete/2
%% copied out of the pool, of any size, and returns the request's result or a reason built
%% from fixed atoms and integers, never an atom made from the device's bytes.

-module(erx_blk_request).

-export([identify/3, capacity/2, range/3, decode/2]).
-export([max_sectors/0, buffer_size/0]).

-export_type([request/0, reason/0]).

-include("generated/erx_abi.hrl").

%% The most sectors one request moves, which sizes the queue's buffers: a header, the
%% sectors and the status byte, end to end in one buffer (erx_device:queue_create/4).
-define(MAX_SECTORS, 8).
-define(STATUS_BYTES, 1).

%% What a completion answers, as the device process remembers it beside the tag it posted.
-type request() :: {read, Count :: pos_integer()} | write.
-type reason() :: out_of_range | bad_count | ioerr | unsupp | {status, 0..255}
                | {length, non_neg_integer()}.

-spec max_sectors() -> pos_integer().
max_sectors() -> ?MAX_SECTORS.

-spec buffer_size() -> pos_integer().
buffer_size() ->
    ?ERX_VIRTIO_BLK_REQ_HEADER_SIZE + ?MAX_SECTORS * ?ERX_VIRTIO_BLK_SECTOR_SIZE + ?STATUS_BYTES.

%% Whether the first registers of a transport say a virtio-mmio version 2 block device. The
%% reason carries the word that disagreed, so the driver's one line says what it found.
-spec identify(non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
          ok | {error, {magic | version | device_id, non_neg_integer()}}.
identify(Magic, _Version, _DeviceId) when Magic =/= ?ERX_VIRTIO_MMIO_MAGIC -> {error, {magic, Magic}};
identify(_Magic, Version, _DeviceId) when Version =/= ?ERX_VIRTIO_MMIO_VERSION -> {error, {version, Version}};
identify(_Magic, _Version, DeviceId) when DeviceId =/= ?ERX_VIRTIO_ID_BLOCK -> {error, {device_id, DeviceId}};
identify(_Magic, _Version, _DeviceId) -> ok.

%% The capacity in sectors from the configuration space's two 32-bit words.
-spec capacity(0..16#ffffffff, 0..16#ffffffff) -> non_neg_integer().
capacity(Low, High) -> (High bsl 32) bor Low.

%% Whether Count sectors from Sector lie on a device of Capacity sectors, and Count is one
%% request's worth. The sum is an Erlang integer, so it cannot wrap.
-spec range(term(), term(), non_neg_integer()) -> ok | {error, out_of_range | bad_count}.
range(_Sector, Count, _Capacity) when not is_integer(Count); Count < 1; Count > ?MAX_SECTORS ->
    {error, bad_count};
range(Sector, _Count, _Capacity) when not is_integer(Sector); Sector < 0 ->
    {error, out_of_range};
range(Sector, Count, Capacity) when Sector + Count > Capacity ->
    {error, out_of_range};
range(_Sector, _Count, _Capacity) ->
    ok.

%% The result of a request from the bytes the device wrote into its in segments, end to end
%% and cut at the length it reported. A read must have written every sector and the status;
%% a write only the status. Any other length is refused whole: the status byte is the last
%% one written, so a short completion has no status to believe.
-spec decode(request(), binary()) -> ok | {ok, binary()} | {error, reason()}.
decode({read, Count}, Bytes) ->
    Size = Count * ?ERX_VIRTIO_BLK_SECTOR_SIZE,
    case Bytes of
        <<Data:Size/binary, Status:8>> ->
            case status(Status) of
                ok -> {ok, Data};
                Error -> Error
            end;
        _ ->
            {error, {length, byte_size(Bytes)}}
    end;
decode(write, <<Status:8>>) ->
    status(Status);
decode(write, Bytes) ->
    {error, {length, byte_size(Bytes)}}.

status(?ERX_VIRTIO_BLK_S_OK) -> ok;
status(?ERX_VIRTIO_BLK_S_IOERR) -> {error, ioerr};
status(?ERX_VIRTIO_BLK_S_UNSUPP) -> {error, unsupp};
status(Other) -> {error, {status, Other}}.
