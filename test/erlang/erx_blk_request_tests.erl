%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the block driver's pure core: erx_blk_request's checks, headers and
%% decoding of what the device wrote, and the segments erx_blk_write, the one module that posts, builds.
%% test/host/erx_blk_request_test.rb runs them on stock's emulator.

-module(erx_blk_request_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).

identify_test_() ->
    Magic = 16#74726976,
    [?_assertEqual(ok, erx_blk_request:identify(Magic, 2, 2)),
     ?_assertEqual({error, {magic, 0}}, erx_blk_request:identify(0, 2, 2)),
     ?_assertEqual({error, {version, 1}}, erx_blk_request:identify(Magic, 1, 2)),
     ?_assertEqual({error, {device_id, 0}}, erx_blk_request:identify(Magic, 2, 0)),
     %% QEMU's empty transport offers the legacy interface unless told otherwise: it is
     %% still no device, not a device of the wrong version.
     ?_assertEqual({error, {device_id, 0}}, erx_blk_request:identify(Magic, 1, 0)),
     ?_assertEqual({error, {device_id, 1}}, erx_blk_request:identify(Magic, 2, 1))].

capacity_test_() ->
    [?_assertEqual(16, erx_blk_request:capacity(16, 0)),
     ?_assertEqual(16#100000010, erx_blk_request:capacity(16, 1)),
     ?_assertEqual(16#ffffffffffffffff, erx_blk_request:capacity(16#ffffffff, 16#ffffffff))].

range_test_() ->
    Max = erx_blk_request:max_sectors(),
    [?_assertEqual(ok, erx_blk_request:range(0, 1, 16)),
     ?_assertEqual(ok, erx_blk_request:range(15, 1, 16)),
     ?_assertEqual(ok, erx_blk_request:range(8, Max, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_request:range(16, 1, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_request:range(15, 2, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_request:range(-1, 1, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_request:range(0, 1, 0)),
     ?_assertEqual({error, out_of_range}, erx_blk_request:range(sector, 1, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_request:range(1 bsl 64, 1, 1 bsl 64)),
     ?_assertEqual({error, bad_count}, erx_blk_request:range(0, 0, 16)),
     ?_assertEqual({error, bad_count}, erx_blk_request:range(0, Max + 1, 1 bsl 20)),
     ?_assertEqual({error, bad_count}, erx_blk_request:range(0, 1.0, 16))].

%% A buffer holds one request of the most sectors: header, sectors, status.
buffer_size_test() ->
    ?assertEqual(16 + erx_blk_request:max_sectors() * ?SECTOR + 1, erx_blk_request:buffer_size()).

read_segments_test_() ->
    [?_assertEqual({ok, [{out, <<0:32/little, 0:32/little, 3:64/little>>}, {in, 2 * ?SECTOR}, {in, 1}]},
                   erx_blk_write:read_segments(3, 2, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_write:read_segments(16, 1, 16)),
     ?_assertEqual({error, bad_count}, erx_blk_write:read_segments(0, 0, 16))].

write_segments_test_() ->
    Data = binary:copy(<<"w">>, ?SECTOR),
    [?_assertEqual({ok, [{out, <<1:32/little, 0:32/little, 7:64/little>>}, {out, Data}, {in, 1}]},
                   erx_blk_write:write_segments(7, Data, 16)),
     ?_assertEqual({error, out_of_range}, erx_blk_write:write_segments(16, Data, 16)),
     ?_assertEqual({error, bad_count}, erx_blk_write:write_segments(0, <<>>, 16)),
     ?_assertEqual({error, bad_count}, erx_blk_write:write_segments(0, <<0>>, 16)),
     ?_assertEqual({error, bad_count}, erx_blk_write:write_segments(0, [Data], 16)),
     ?_assertEqual({error, bad_count},
                   erx_blk_write:write_segments(0, binary:copy(Data, erx_blk_request:max_sectors() + 1), 1 bsl 20))].

decode_read_test_() ->
    Data = binary:copy(<<"r">>, 2 * ?SECTOR),
    [?_assertEqual({ok, Data}, erx_blk_request:decode({read, 2}, <<Data/binary, 0>>)),
     ?_assertEqual({error, ioerr}, erx_blk_request:decode({read, 2}, <<Data/binary, 1>>)),
     ?_assertEqual({error, unsupp}, erx_blk_request:decode({read, 2}, <<Data/binary, 2>>)),
     ?_assertEqual({error, {status, 255}}, erx_blk_request:decode({read, 2}, <<Data/binary, 255>>)),
     ?_assertEqual({error, {length, 1024}}, erx_blk_request:decode({read, 2}, Data)),
     ?_assertEqual({error, {length, 1026}}, erx_blk_request:decode({read, 2}, <<Data/binary, 0, 0>>)),
     ?_assertEqual({error, {length, 0}}, erx_blk_request:decode({read, 2}, <<>>))].

decode_write_test_() ->
    [?_assertEqual(ok, erx_blk_request:decode(write, <<0>>)),
     ?_assertEqual({error, ioerr}, erx_blk_request:decode(write, <<1>>)),
     ?_assertEqual({error, {status, 3}}, erx_blk_request:decode(write, <<3>>)),
     ?_assertEqual({error, {length, 0}}, erx_blk_request:decode(write, <<>>)),
     ?_assertEqual({error, {length, 2}}, erx_blk_request:decode(write, <<0, 0>>))].
