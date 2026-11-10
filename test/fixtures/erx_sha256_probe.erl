%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_sha256_probe).

-moduledoc """
Judges erx_bytes's SHA-256 calls in a running erXos release
(test/integration/runtime_hosted_smoke_test.rb). The host test runs `digests/1` on the stock
OTP oracle with `crypto:hash/2`, then loads this module into the release and hands those
digests to `check/1`, which compares them with `erx_bytes:sha256/1` over the same messages and
also checks FIPS 180-4's examples, streaming over random cuts against one-shot digests, the
reuse of a state, and the refusal of every malformed argument. The messages come from a fixed
seed of `rand`, so both runtimes, which are the same OTP release, make the same bytes.
""".

-export([digests/1, check/1]).

%% Lengths around SHA-256's block (64 bytes) and its padding (55, 56, 119, 120), and around
%% the pieces of 65536 bytes that erx_bytes:sha256_update/2 works in.
-define(LENGTHS, [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 65535, 65536, 65537, 131072,
                  200000]).
-define(CUTS_PER_MESSAGE, 6).

-doc "The lowercase hex digests by `Hash` of the probe's messages, in order.".
-spec digests(fun((binary()) -> binary())) -> [binary()].
digests(Hash) ->
    [binary:encode_hex(Hash(Message), lowercase) || Message <- messages()].

-doc """
`{sha256, Fips, Oracle, Cuts, Refusals}`, where each list is empty when its check passed:
the names of FIPS examples digested wrongly, the indices of messages whose digest differs
from `Expected` (the oracle's `digests/1`), `{Length, Check}` for each message and way of
streaming it that disagreed with its one-shot digest (see `cuts/0`), and the results of
malformed calls that did not fail with `badarg`.
""".
-spec check([binary()]) -> {sha256, [atom()], [pos_integer()] | length,
                                    [{non_neg_integer(), atom()}], [term()]}.
check(Expected) ->
    {sha256, fips(), oracle(Expected), cuts(), refusals()}.

%% FIPS 180-4's examples (NIST's "SHA-256" example computations) and the million "a"s of its
%% earlier editions, which takes sixteen NIF calls.
fips() ->
    Vectors = [{abc, <<"abc">>,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
               {empty, <<>>,
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
               {two_blocks, <<"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq">>,
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
               {long, <<"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn",
                        "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu">>,
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"},
               {million_a, binary:copy(<<"a">>, 1000000),
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"}],
    [Name || {Name, Message, Digest} <- Vectors,
             binary:encode_hex(erx_bytes:sha256(Message), lowercase) =/= list_to_binary(Digest)].

oracle(Expected) ->
    case digests(fun erx_bytes:sha256/1) of
        Ours when length(Ours) =:= length(Expected) ->
            [Index || {Index, Mine, Theirs} <- lists:zip3(lists:seq(1, length(Ours)), Ours, Expected),
                      Mine =/= Theirs];
        _ ->
            length
    end.

%% Each message, streamed over CUTS_PER_MESSAGE random cuts, gives its one-shot digest, and so
%% does each other way of reaching it. A failure is the message's length and the check that
%% disagreed: cut_streams; reused_state, a state extended twice the same way; finished_prefix,
%% a state finished twice and against the one-shot digest of its bytes; or unaligned, the
%% message as a binary at a bit offset, which the NIF copies before it reads it.
cuts() ->
    Seed = rand:seed_s(exsss, {2026, 11, 7}),
    {Failures, _} = lists:foldl(fun cut_message/2, {[], Seed}, messages()),
    lists:reverse(Failures).

cut_message(Message, {Failures, Seed}) ->
    Whole = erx_bytes:sha256(Message),
    {Pieces, Seed1} = lists:mapfoldl(fun(_, S) -> random_pieces(Message, S) end, Seed,
                                     lists:seq(1, ?CUTS_PER_MESSAGE)),
    Half = byte_size(Message) div 2,
    <<Head:Half/binary, Tail/binary>> = Message,
    Shared = erx_bytes:sha256_update(erx_bytes:sha256_init(), Head),
    Checks = [{cut_streams, [streamed(Cut) || Cut <- Pieces]},
              {reused_state, [erx_bytes:sha256_final(erx_bytes:sha256_update(Shared, Tail)),
                              erx_bytes:sha256_final(erx_bytes:sha256_update(Shared, Tail))]},
              {finished_prefix, [erx_bytes:sha256_final(Shared), erx_bytes:sha256_final(Shared)],
               erx_bytes:sha256(Head)},
              {unaligned, [erx_bytes:sha256(unaligned(Message)),
                           streamed([unaligned(Message)])]}],
    Failed = [{byte_size(Message), Name} || Check <- Checks, {Name, false} <- [agrees(Check, Whole)]],
    {lists:reverse(Failed, Failures), Seed1}.

%% {Name, true} when every digest of the check is its expected one: the whole message's, unless
%% the check names its own.
agrees({Name, Digests}, Whole) -> agrees({Name, Digests, Whole}, Whole);
agrees({Name, Digests, Expected}, _Whole) ->
    {Name, lists:all(fun(Digest) -> Digest =:= Expected end, Digests)}.

%% Message's bytes as a sub-binary three bits into a larger one.
unaligned(Message) ->
    Size = byte_size(Message),
    <<_:3, Unaligned:Size/binary, _:5>> = <<0:3, Message/binary, 0:5>>,
    Unaligned.

streamed(Pieces) ->
    erx_bytes:sha256_final(lists:foldl(fun(Piece, State) -> erx_bytes:sha256_update(State, Piece) end,
                                       erx_bytes:sha256_init(), Pieces)).

%% Message cut at up to five random offsets, empty pieces included. uniform_s(N + 1) draws
%% 1..N + 1, so each offset less one is a cut point in 0..N.
random_pieces(Message, Seed) ->
    {Count, Seed1} = rand:uniform_s(6, Seed),
    {Offsets, Seed2} = lists:mapfoldl(fun(_, S) -> rand:uniform_s(byte_size(Message) + 1, S) end,
                                      Seed1, lists:seq(1, Count - 1)),
    Bounds = [0 | lists:sort([Offset - 1 || Offset <- Offsets])] ++ [byte_size(Message)],
    {[binary:part(Message, From, To - From) || {From, To} <- lists:zip(lists:droplast(Bounds), tl(Bounds))],
     Seed2}.

%% Each malformed call must fail with badarg: a bitstring, a list, a long bitstring, and a state
%% that is not one, a plain reference or another kind of magic reference, which the BIFs must
%% never read as a SHA-256 context.
refusals() ->
    State = erx_bytes:sha256_init(),
    Calls = [fun() -> erx_bytes:sha256(<<1:7>>) end,
             fun() -> erx_bytes:sha256(<<0:(65536 * 8 + 3)>>) end,
             fun() -> erx_bytes:sha256("abc") end,
             fun() -> erx_bytes:sha256_update(State, <<1:7>>) end,
             fun() -> erx_bytes:sha256_update(State, <<0:(65536 * 8 * 2 + 3)>>) end,
             fun() -> erx_bytes:sha256_update(make_ref(), <<"abc">>) end,
             fun() -> erx_bytes:sha256_update(make_ref(), binary:copy(<<"a">>, 70000)) end,
             fun() -> erx_bytes:sha256_update(<<>>, <<>>) end,
             fun() -> erx_bytes:sha256_final(make_ref()) end,
             fun() -> erx_bytes:sha256_final(atomics:new(1, [])) end,
             fun() -> erx_bytes:sha256_final(counters:new(1, [])) end,
             fun() -> erx_bytes:sha256_update(atomics:new(1, []), <<"abc">>) end,
             fun() -> erx_bytes:sha256_update(counters:new(1, []), <<"abc">>) end,
             fun() -> erx_bytes:sha256_final(<<0:832>>) end],
    [Result || Result <- [refused(Call) || Call <- Calls], Result =/= badarg].

refused(Call) ->
    try Call() of
        Value -> {returned, Value}
    catch
        error:badarg -> badarg;
        Class:Reason -> {Class, Reason}
    end.

messages() ->
    Seed = rand:seed_s(exsss, {2026, 11, 6}),
    {Messages, _} = lists:mapfoldl(fun rand:bytes_s/2, Seed, ?LENGTHS),
    Messages.
