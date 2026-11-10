%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes_bench).
-moduledoc """
The per-byte primitives of erx_net's segments, timed on erXos by `tools/erx bench bytes`
through the functions the stack calls: `erx_bytes:siphash24/2` over 20 bytes (a connection's
ISN input) and 8 (an IPv4 ID draw), and `erx_bytes:inet_csum/2` over a 20-byte header and a
1460-byte payload as an iolist, over one 1480-byte binary, over a 12-byte pseudo-header and
over an IPv4 header's two pieces. `loop` is the same loop calling a local function of two
arguments, the overhead every other workload carries. The same module times any image, so
two images' numbers compare their implementations of `erx_bytes`.
""".

-export([run/2]).

-define(KEY, <<0:64, 1:64>>).

-doc """
Times every workload Samples times, Iterations calls a sample, after one unreported warm-up
of each. The samples of the workloads are interleaved, round by round, so a change in the
host's load reaches every workload alike.
""".
-spec run(pos_integer(), pos_integer()) -> map().
run(Iterations, Samples) ->
    _ = [sample(Workload, min(Iterations, 1000)) || Workload <- workloads()],
    Rounds = [[{Workload, sample(Workload, Iterations)} || Workload <- workloads()]
              || _ <- lists:seq(1, Samples)],
    Measured = maps:groups_from_list(fun({W, _}) -> W end, fun({_, V}) -> V end, lists:append(Rounds)),
    #{iterations => Iterations, samples => Samples,
      workloads => #{atom_to_binary(W) => #{status => measured, ns_per_call => Values}
                     || W := Values <- Measured},
      beam_md5 => binary:encode_hex(?MODULE:module_info(md5), lowercase),
      emu_flavor => atom_to_binary(erlang:system_info(emu_flavor)),
      schedulers => erlang:system_info(schedulers_online)}.

workloads() -> [loop, siphash20, siphash8, csum_iolist, csum_binary, csum_pseudo, csum_ip_header].

%% The inputs: a segment's 20-byte TCP header and its 1460-byte payload, each its own binary
%% as the stack builds them, and SipHash's 20 bytes, a connection's four-tuple and its key.
header() -> binary:copy(<<16#45>>, 20).
payload() -> binary:copy(<<16#a5>>, 1460).
segment() -> binary:copy(<<16#5a>>, 1480).
%% IPv4's 12-byte pseudo-header, and its header as erx_ip4_wire:encode sums it, two pieces.
pseudo() -> binary:copy(<<16#0a>>, 12).
ip_header() -> [binary:copy(<<16#45>>, 10), binary:copy(<<16#0a>>, 8)].

sample(Workload, Iterations) ->
    Start = erlang:monotonic_time(nanosecond),
    _ = loop(Workload, Iterations),
    (erlang:monotonic_time(nanosecond) - Start) / Iterations.

loop(loop, N) -> local(N, ?KEY, header(), 0);
loop(siphash20, N) -> siphash(N, ?KEY, header(), 0);
loop(siphash8, N) -> siphash(N, ?KEY, <<7:64>>, 0);
loop(csum_iolist, N) -> csum(N, [header(), payload()], 0);
loop(csum_binary, N) -> csum(N, segment(), 0);
loop(csum_pseudo, N) -> csum(N, pseudo(), 0);
loop(csum_ip_header, N) -> csum(N, ip_header(), 0).

%% Each loop folds its results into an accumulator, so no call is dead code.
local(0, _Key, _Data, Acc) -> Acc;
local(N, Key, Data, Acc) -> local(N - 1, Key, Data, Acc bxor identity(Key, Data)).

siphash(0, _Key, _Data, Acc) -> Acc;
siphash(N, Key, Data, Acc) -> siphash(N - 1, Key, Data, Acc bxor erx_bytes:siphash24(Key, Data)).

csum(0, _Data, Acc) -> Acc;
csum(N, Data, Acc) -> csum(N - 1, Data, Acc bxor erx_bytes:inet_csum(0, Data)).

identity(Key, Data) when is_binary(Key) -> byte_size(Data).
