%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_rand).
-moduledoc """
The network stack's random generator (docs/design-network-stack.md, "Random values are
state, not context"), the role FreeBSD gives `arc4random`. Every owner keeps one in its
state as a pure value: a step draws from the generator it was given and returns the advanced
one, so a fixed key gives the same values on every run.

A generator is a 16-byte key and a block counter. Block `I` of its stream is
`erx_bytes:siphash24(Key, <<(Counter + I):64>>)`, written as eight little-endian bytes, the
byte order of SipHash's own output. Every draw advances the counter past the blocks it used,
so no block is given twice: `bytes/2` takes as many blocks as its bytes need and drops the
rest of the last one, `uniform/2` takes one, and `split/1` takes two as its child's key.
SipHash-2-4 is used here as a keyed pseudorandom function over the counter, the assumption
the initial sequence numbers and SYN cookies already rest on: its outputs reveal neither the
key nor later outputs. A draw that would use a block past the 2^64th raises `exhausted`,
which no owner reaches.

Keys come from `erx_bytes:entropy/1` in an owner's initialisation, or from `split/1` of the
spawner's generator; this module never reads entropy itself, and nothing in erx_net uses
`rand`, whose algorithms an observer of a few outputs can predict.
""".

-export([new/1, bytes/2, uniform/2, split/1]).

-export_type([gen/0]).

%% The count of blocks a counter can name: block numbers are 64-bit.
-define(BLOCKS, (1 bsl 64)).

%% The most bytes one draw gives, ten times the 16-byte keys and nonces owners draw.
-define(BYTES_MAX, 256).

-doc "A generator: its key and the number of the next block of its stream.".
-opaque gen() :: {Key :: <<_:128>>, Counter :: 0..?BLOCKS}.

-doc "A generator keyed with `Key`, its counter at zero. Fails with `badarg` unless `Key` is 16 bytes.".
-spec new(Key :: <<_:128>>) -> gen().
new(<<_:128>> = Key) ->
    {Key, 0};
new(_Key) ->
    erlang:error(badarg).

-doc """
`N` bytes of the stream and the generator advanced past the blocks they used: the first `N`
bytes of the next `ceil(N / 8)` blocks. Fails with `badarg` unless `N` is an integer from 0
to 256, and with `exhausted` if the stream has too few blocks left.
""".
-spec bytes(N :: 0..?BYTES_MAX, gen()) -> {binary(), gen()}.
bytes(N, {Key, Counter}) when is_integer(N), N >= 0, N =< ?BYTES_MAX ->
    Next = advance(Counter, (N + 7) div 8),
    <<Bytes:N/binary, _/binary>> = stream(Key, Counter, Next),
    {Bytes, {Key, Next}};
bytes(_N, _Gen) ->
    erlang:error(badarg).

-doc """
An integer in `0..Range-1` and the generator advanced past the one block it used: the block
modulo `Range`, a bias below `Range / 2^64`. Fails with `badarg` unless `Range` is an integer
in `1..2^64`, and with `exhausted` if the stream is used up.
""".
-spec uniform(Range :: pos_integer(), gen()) -> {non_neg_integer(), gen()}.
uniform(Range, {Key, Counter}) when is_integer(Range), Range >= 1, Range =< ?BLOCKS ->
    Next = advance(Counter, 1),
    {block(Key, Counter) rem Range, {Key, Next}};
uniform(_Range, _Gen) ->
    erlang:error(badarg).

-doc """
A child generator for an owner this one's owner spawns, and this generator advanced past the
two blocks the child's key took: the child is `new/1` of the next 16 bytes of the stream, so
no block is both drawn and used as a key, and no two children share a key. Fails with
`exhausted` if fewer than two blocks are left.
""".
-spec split(gen()) -> {Child :: gen(), gen()}.
split(Gen) ->
    {Key, Advanced} = bytes(16, Gen),
    {new(Key), Advanced}.

%% The counter after Blocks more blocks, or exhausted if one of them would be past the last.
advance(Counter, Blocks) when Counter + Blocks =< ?BLOCKS ->
    Counter + Blocks;
advance(_Counter, _Blocks) ->
    erlang:error(exhausted).

%% Blocks From to To - 1 of Key's stream, eight little-endian bytes each.
stream(Key, From, To) ->
    << <<(block(Key, I)):64/little>> || I <- lists:seq(From, To - 1) >>.

block(Key, I) ->
    erx_bytes:siphash24(Key, <<I:64>>).
