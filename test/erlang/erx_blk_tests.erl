%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the block driver's choice of transport, erx_blk:choose/1: which device
%% process the domain's block records start, from what erx_device_record:find/3 makes of
%% the records init would hold. test/host/erx_blk_test.rb runs them on stock's emulator.

-module(erx_blk_tests).
-include_lib("eunit/include/eunit.hrl").

%% A given block record of Peripheral, as the domain library writes it.
record(Peripheral) ->
    ["given", "block", atom_to_list(Peripheral), "5", "0", "512", "6", "direct", "7", "65536", "0"].

%% erx_blk:start_link/0's lookup over Arguments in place of init's.
choose(Arguments) ->
    erx_blk:choose([{Peripheral, erx_device_record:find(block, Peripheral, Arguments)}
                    || {Peripheral, _Transport} <- erx_blk:transports()]).

virtio_record_starts_the_virtio_process_test() ->
    ?assertMatch({ok, erx_blk_virtio, #{peripheral := virtio_mmio, window := {object, 5, 0, 512}}},
                 choose([record(virtio_mmio)])).

no_block_record_starts_nothing_test_() ->
    [?_assertEqual(none, choose([])),
     ?_assertEqual(none, choose([["given", "net", "virtio_mmio", "5", "0", "512", "6", "direct", "7", "65536", "0"]]))].

sdhci_record_has_no_transport_test() ->
    ?assertEqual({error, {sdhci, no_transport}}, choose([record(sdhci)])).

several_block_records_are_refused_test_() ->
    [?_assertEqual({error, {block_records, [virtio_mmio, virtio_mmio]}},
                   choose([record(virtio_mmio), record(virtio_mmio)])),
     ?_assertEqual({error, {block_records, [virtio_mmio, sdhci]}}, choose([record(sdhci), record(virtio_mmio)]))].

%% A record that does not parse refuses the choice, and its text stays out of the reason.
unreadable_record_is_refused_test() ->
    ?assertEqual({error, {bad_device_record, [virtio_mmio]}},
                 choose([record(virtio_mmio), ["given", "block", "virtio_mmio", "x"]])).

%% A record of one peripheral that does not parse refuses a good record of another as well.
unreadable_record_of_another_peripheral_is_refused_test() ->
    ?assertEqual({error, {bad_device_record, [sdhci]}},
                 choose([record(virtio_mmio), ["given", "block", "sdhci", "x"]])).
