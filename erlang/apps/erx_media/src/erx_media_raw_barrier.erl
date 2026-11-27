%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_raw_barrier).
-moduledoc """
The barrier of a medium's raw process (docs/design-drives.md, "Raw sectors"), its pure
core: the counts that decide when what the raw process holds returns to service, and
when its finish answers. erx_media_raw feeds it every event and performs the actions it
answers, in order.

It counts two things. The **writers** are the medium's writing opens, each counted from
its arrival, before the drive process is asked for its volumes, until it leaves the
count: closed by a clunk, by its holder's or its grant's end, or refused. The **sent**
are the requests the raw process has queued for the window and not yet seen answered:
a client's read or write, an open's flush, an fsync, the barrier's own flush and the
finish's. **Wrote** says whether a write has reached the window since the barrier last
flushed, or since the raw process took what it holds.

The one rule: when no writer remains, nothing sent is unanswered and the raw process
holds something, it hands everything back, after a flush when it wrote. A flush that
answers anything but `ok` fails the raw process, which ends the medium. A finish (an
eject or the ordered end) closes the barrier for good: nothing is handed back, and once
nothing sent is unanswered the finish's flush is sent and its answer is the finish's.

Events:

* `arrive`: a writing open arrived;
* `leave`: a writing open left the count;
* `{took, Covers}`: the drive process took Covers out of service for the raw process,
  each `{volume, N}` or `medium`;
* `queued`: a request was queued for the window;
* `wrote`: a write of a queued request reached the window;
* `answered`: a queued request was answered, or dropped before it reached the window;
* `{flushed, Answer}`: the barrier's or the finish's flush was answered;
* `finish`: the drive process sent the raw process its finish.

Actions:

* `flush`: send the window the barrier's or the finish's flush, already counted as sent;
* `{hand_back, Covers}`: hand Covers back to the drive process;
* `{fail, Why}`: end the raw process, which ends the medium;
* `{finished, Answer}`: answer the finish.
""".

-export([new/0, step/2, holds/1, finishing/1]).
-export_type([barrier/0, event/0, action/0, cover/0]).

-type cover() :: {volume, non_neg_integer()} | medium.
-type event() :: arrive | leave | {took, [cover()]} | queued | wrote | answered
               | {flushed, term()} | finish.
-type action() :: flush | {hand_back, [cover()]} | {fail, term()} | {finished, term()}.

%% flushing is none, barrier or finish: which flush is on its way, if any.
-record(barrier, {writers = 0 :: non_neg_integer(),
                  sent = 0 :: non_neg_integer(),
                  wrote = false :: boolean(),
                  held = [] :: [cover()],
                  flushing = none :: none | barrier | finish,
                  finishing = no :: no | yes | done}).
-opaque barrier() :: #barrier{}.

-doc "A barrier with no writer, nothing sent and nothing held.".
-spec new() -> barrier().
new() -> #barrier{}.

-doc "What the raw process holds out of service, sorted.".
-spec holds(barrier()) -> [cover()].
holds(#barrier{held = Held}) -> Held.

-doc "Whether the raw process has been sent its finish.".
-spec finishing(barrier()) -> boolean().
finishing(#barrier{finishing = Finishing}) -> Finishing =/= no.

-doc """
The barrier after Event and the actions that follow it. An event the counts do not
allow, a leave with no writer or an answer with nothing sent, fails with
`function_clause`: the raw process has lost track of its own requests.
""".
-spec step(event(), barrier()) -> {[action()], barrier()}.
step(arrive, #barrier{writers = W} = B) ->
    {[], B#barrier{writers = W + 1}};
step(leave, #barrier{writers = W} = B) when W > 0 ->
    test(B#barrier{writers = W - 1});
%% A take answered after its open left the count holds what it took all the same, so
%% the rule is tested: no writer may remain to close.
step({took, Covers}, #barrier{held = Held} = B) ->
    test(B#barrier{held = lists:usort(Held ++ Covers)});
step(queued, #barrier{sent = S} = B) ->
    {[], B#barrier{sent = S + 1}};
step(wrote, #barrier{sent = S} = B) when S > 0 ->
    {[], B#barrier{wrote = true}};
step(answered, #barrier{sent = S} = B) when S > 0 ->
    test(B#barrier{sent = S - 1});
step({flushed, Answer}, #barrier{sent = S, flushing = finish} = B) when S > 0 ->
    {[{finished, Answer}], B#barrier{sent = S - 1, flushing = none, finishing = done}};
step({flushed, ok}, #barrier{sent = S, flushing = barrier} = B) when S > 0 ->
    test(B#barrier{sent = S - 1, flushing = none});
step({flushed, Answer}, #barrier{sent = S, flushing = barrier} = B) when S > 0 ->
    {[{fail, {flush, Answer}}], B#barrier{sent = S - 1, flushing = none}};
step(finish, #barrier{finishing = no} = B) ->
    test(B#barrier{finishing = yes}).

%% The one rule, tested after every event that can open the barrier.
test(#barrier{flushing = Flushing} = B) when Flushing =/= none ->
    {[], B};
test(#barrier{finishing = yes, sent = 0} = B) ->
    {[flush], B#barrier{sent = 1, flushing = finish}};
test(#barrier{finishing = Finishing} = B) when Finishing =/= no ->
    {[], B};
test(#barrier{writers = 0, sent = 0, held = Held, wrote = true} = B) when Held =/= [] ->
    {[flush], B#barrier{sent = 1, flushing = barrier, wrote = false}};
test(#barrier{writers = 0, sent = 0, held = Held, wrote = false} = B) when Held =/= [] ->
    {[{hand_back, Held}], B#barrier{held = []}};
test(B) ->
    {[], B}.
