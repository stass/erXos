%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_sendlog).
-moduledoc """
The TCP sender's record of what it has sent (docs/design-network-stack.md, "The send log,
SACK and reassembly"), and RFC 6675's scoreboard computed from it: SACKed bytes, `IsLost`
(RFC 6675 section 4), `NextSeg` (section 4) and the pipe (`SetPipe`, section 4). It is
written from RFC 6675, not translated: FreeBSD's sender-side scoreboard lives in
`sys/netinet/tcp_sack.c`, whose notice carries an advertising clause erXos does not take.

The log tiles `[snd_una, snd_max)` with ranges, an ordered map from each range's first
byte to `#sent{}`: where it ends, when it was last sent, how often, and three marks.
`sacked` is RFC 6675's SACKed. `lost` is `IsLost`, set by the loss module (`mark_lost/3`
computes RFC 6675's definition; `lose/2` marks what NewReno infers lost; `timeout/2`
marks everything). `rxt` is "retransmitted during the current recovery", RFC 6675's octets
at or below `HighRxt`, kept per range for the pipe; `HighRxt` itself is kept too, as the
point `NextSeg` searches from. Neighbouring SACKed ranges merge, so a run of SACKed data is
one range. Sequence numbers are unwrapped integers.

Invariants:
* The ranges tile `[snd_una, snd_max)` exactly, without gaps or overlaps.
* Only the sender's own transmissions create range boundaries (`sent/4`, `rescued/5`,
  and an acknowledgement that cuts a range at `snd_una`). A SACK block marks only the
  ranges it covers whole, so a peer cannot split the log into pieces smaller than what
  was sent, and the log never holds more ranges than the sender made. Merging SACKed
  neighbours only removes boundaries, and makes each acknowledgement's work proportional
  to the ranges it newly SACKs, not to the window.
* The unSACKed ranges marked lost are a prefix of the unSACKed ranges. `IsLost` is
  monotone in that direction (a byte below a lost byte has at least as much SACKed data
  above it), and every marking keeps it: `mark_lost/3` marks downward, `lose/2` marks
  from `snd_una` up, `timeout/2` marks all.
* The counters `sacked`, `lost` and `rxt` are the byte totals of SACKed ranges, of
  unSACKed lost ranges and of unSACKed retransmitted ranges. Every change of a range
  goes through `store/4`, which keeps them, so the pipe is a constant-time sum:
  `(snd_max - snd_una) - sacked - lost + rxt`, RFC 6675's `SetPipe`.
""".

-export([new/1, sent/4, rescued/5, ack/3, mark_lost/3, lose/2, timeout/2, timeout_undone/1,
         resend_holes/1,
         next_seg/2]).
-export([snd_una/1, snd_max/1, snd_fack/1, pipe/1, flight/1, sacked_bytes/1, sent_bytes/1,
         has_holes/1, to_list/1]).
-export_type([log/0, ack_info/0, next_seg_opts/0, segment/0]).

-record(sent, {
    next :: integer(),                  % the sequence number after the range
    sent_at :: integer(),               % the last transmission, monotonic microseconds
    transmissions = 1 :: pos_integer(),
    sacked = false :: boolean(),
    lost = false :: boolean(),
    rxt = false :: boolean()
}).

-record(sendlog, {
    una :: integer(),                   % snd_una, RFC 6675's HighACK
    max :: integer(),                   % snd_max, RFC 6675's HighData plus one
    fack :: integer(),                  % the end of the highest SACKed range, at least una
    high_rxt :: integer(),              % RFC 6675's HighRxt plus one, at least una
    ranges = gb_trees:empty() :: gb_trees:tree(integer(), #sent{}),
    sacked = 0 :: non_neg_integer(),
    lost = 0 :: non_neg_integer(),
    rxt = 0 :: non_neg_integer(),
    sent_bytes = 0 :: non_neg_integer(),% every byte ever sent, retransmissions included
    rescue = none :: none | integer()   % RFC 6675's RescueRxt
}).

-doc "The send log of one connection.".
-opaque log() :: #sendlog{}.
-doc """
What an acknowledgement changed: `delivered` is RFC 6937's DeliveredData (the change in
`snd_una` plus the change in SACKed bytes), `sacked` the bytes it newly SACKed.
""".
-type ack_info() :: #{delivered := integer(), sacked := non_neg_integer()}.
-doc """
`NextSeg`'s inputs: the segment size; `recover`, past which nothing is retransmitted
(`snd_recover` during recovery, as FreeBSD's `tcp_output` limits it, and `snd_max`
otherwise); whether unsent data may go now (rule 2); whether rule 4's rescue
retransmission applies, which is only in SACK-based recovery.
""".
-type next_seg_opts() :: #{mss := pos_integer(), recover := integer(), new_data := boolean(),
                           rescue := boolean()}.
-doc "`NextSeg`'s answer: retransmit `[Start, Next)`, send new data, or nothing.".
-type segment() :: {retransmit, integer(), integer()} | {rescue, integer(), integer()} | new | none.

-doc "An empty log for a connection whose first unacknowledged byte is `Una`.".
-spec new(integer()) -> log().
new(Una) when is_integer(Una) -> #sendlog{una = Una, max = Una, fack = Una, high_rxt = Una}.

-doc """
Records the transmission of `[Start, Next)` at `Now`. The part at or past `snd_max` is new
data; the part below is a retransmission, which counts as `HighRxt` moving over it
(RFC 6675 section 5, step (C)). `Start` lies in `[snd_una, snd_max]`.
""".
-spec sent(log(), integer(), integer(), integer()) -> log().
sent(#sendlog{una = Una, max = Max} = Log0, Start, Next, Now)
  when is_integer(Start), is_integer(Next), is_integer(Now), Una =< Start, Start < Next,
       Start =< Max ->
    Log1 = case Next > Max of
        true -> store(Log0#sendlog{max = Next}, Max, none, #sent{next = Next, sent_at = Now});
        false -> Log0
    end,
    Log2 = case Start < Max of
        true ->
            Log1a = update(Log1, Start, min(Next, Max), fun(S) -> resent(S, Now, true) end),
            Log1a#sendlog{high_rxt = max(Log1a#sendlog.high_rxt, min(Next, Max))};
        false -> Log1
    end,
    count_sent(Log2, Next - Start).

-doc """
Records RFC 6675's rescue retransmission of `[Start, Next)` (section 4, rule 4): it does
not move `HighRxt`, and `RescueRxt` becomes `Recover`, the recovery point.
""".
-spec rescued(log(), integer(), integer(), integer(), integer()) -> log().
rescued(#sendlog{una = Una, max = Max} = Log, Start, Next, Recover, Now)
  when is_integer(Start), is_integer(Next), is_integer(Recover), is_integer(Now),
       Una =< Start, Start < Next, Next =< Max ->
    Log1 = update(Log, Start, Next, fun(S) -> resent(S, Now, false) end),
    count_sent(Log1#sendlog{rescue = Recover}, Next - Start).

-doc """
Applies an acknowledgement: `Ack` acknowledges everything below it, and `Blocks` are the
SACK blocks, `{Left, Right}` with `Right` exclusive, unwrapped by the caller. `Ack` is at
most `snd_max`, as the connection checks before (`tcp_input.c`'s `tcps_rcvacktoomuch`); an
`Ack` at or below `snd_una` acknowledges nothing new. A block is clipped to
`[max(Ack, snd_una), snd_max)` and marks only the ranges it covers whole, so D-SACK blocks
and blocks outside what was sent change nothing.
""".
-spec ack(log(), integer(), [{integer(), integer()}]) -> {log(), ack_info()}.
ack(#sendlog{una = Una0, max = Max, sacked = Sacked0} = Log0, Ack, Blocks)
  when is_integer(Ack), Ack =< Max, is_list(Blocks) ->
    Log1 = advance(Log0, Ack),
    Log2 = lists:foldl(fun sack_block/2, Log1, Blocks),
    Delivered = (Log2#sendlog.una - Una0) + (Log2#sendlog.sacked - Sacked0),
    {Log2, #{delivered => Delivered, sacked => Log2#sendlog.sacked - Log1#sendlog.sacked}}.

-doc """
Marks lost every unSACKed range RFC 6675's `IsLost` holds for: `DupThresh` discontiguous
SACKed sequences above it, or more than `(DupThresh - 1) * Mss` SACKed bytes above it.
Returns the bytes newly marked. The walk goes down from the highest SACKed range and stops
at the first range already lost, since everything below it is lost too.
""".
-spec mark_lost(log(), pos_integer(), pos_integer()) -> {log(), non_neg_integer()}.
mark_lost(#sendlog{ranges = Ranges, fack = Fack} = Log, DupThresh, Mss)
  when is_integer(DupThresh), DupThresh > 0, is_integer(Mss), Mss > 0 ->
    Iter = gb_trees:iterator_from(Fack, Ranges, reversed),
    mark_lost(gb_trees:next(Iter), {DupThresh, (DupThresh - 1) * Mss}, {0, 0, false}, Log, 0).

mark_lost(none, _, _, Log, Newly) ->
    {Log, Newly};
mark_lost({Start, #sent{sacked = true, next = Next}, Iter}, Th, {Above, Runs, InRun}, Log, Newly) ->
    Runs1 = case InRun of true -> Runs; false -> Runs + 1 end,
    mark_lost(gb_trees:next(Iter), Th, {Above + Next - Start, Runs1, true}, Log, Newly);
mark_lost({_, #sent{lost = true}, _}, _, _, Log, Newly) ->
    {Log, Newly};
mark_lost({Start, #sent{next = Next} = Old, Iter}, {DupThresh, Limit} = Th, {Above, Runs, _}, Log,
          Newly) ->
    Below = {Above, Runs, false},
    case Runs >= DupThresh orelse Above > Limit of
        true ->
            Log1 = store(Log, Start, Old, Old#sent{lost = true}),
            mark_lost(gb_trees:next(Iter), Th, Below, Log1, Newly + Next - Start);
        false ->
            mark_lost(gb_trees:next(Iter), Th, Below, Log, Newly)
    end.

-doc """
Marks lost, and not retransmitted, every unSACKed range overlapping `[snd_una, Next)`,
whole: NewReno's inference that the segment at `snd_una` is lost (RFC 6582 section 3.2,
steps 2 and 3), and the bytes a window that shrank to zero took. Marking starts at
`snd_una`, so the lost ranges this marks are always a prefix of the log.
""".
-spec lose(log(), integer()) -> log().
lose(#sendlog{ranges = Ranges} = Log, Next) when is_integer(Next) ->
    lose(gb_trees:next(gb_trees:iterator(Ranges)), Next, Log).

lose({Key, #sent{} = Old, Iter}, Next, Log) when Key < Next ->
    Log1 = case Old#sent.sacked of
        false -> store(Log, Key, Old, Old#sent{lost = true, rxt = false});
        true -> Log
    end,
    lose(gb_trees:next(Iter), Next, Log1);
lose(_, _, Log) ->
    Log.

-doc """
The retransmission timer expired: every unSACKed range is lost and none counts as
retransmitted, and the rescue is forgotten. `keep` keeps the SACK information, as
FreeBSD's first timeout does (`tcp_timer_rexmt` with `t_rxtshift` 1 resends the holes);
`expunge` forgets it, as RFC 6675 section 5.1 and FreeBSD's later timeouts do, since the
receiver may have reneged.
""".
-spec timeout(log(), keep | expunge) -> log().
timeout(#sendlog{ranges = Ranges, una = Una, fack = Fack} = Log, How) when How =:= keep; How =:= expunge ->
    Log1 = lists:foldl(fun({Start, Old}, Acc) -> store(Acc, Start, Old, timed_out(Old, How)) end,
                       Log, gb_trees:to_list(Ranges)),
    Log1#sendlog{rescue = none, high_rxt = Una, fack = case How of keep -> Fack; expunge -> Una end}.

timed_out(#sent{sacked = true} = Sent, keep) -> Sent;
timed_out(Sent, _) -> Sent#sent{sacked = false, lost = true, rxt = false}.

-doc """
The timeout was spurious (CC_RTO_ERR): the original transmissions are still in flight, so
no unSACKed range is lost or counts as retransmitted, and the pipe is again what was sent
less what is SACKed, as FreeBSD's `snd_max - snd_una` is once `snd_nxt` is back at `snd_max`.
""".
-spec timeout_undone(log()) -> log().
timeout_undone(#sendlog{ranges = Ranges, una = Una} = Log) ->
    lists:foldl(fun({Start, #sent{sacked = false} = Old}, Acc) ->
                        store(Acc, Start, Old, Old#sent{lost = false, rxt = false});
                   (_, Acc) -> Acc
                end, Log#sendlog{high_rxt = Una}, gb_trees:to_list(Ranges)).

-doc """
Recovery begins: no unSACKed range counts as retransmitted, so the holes are sent again
(FreeBSD's `tcp_resend_sackholes` at the entry to recovery after a timeout).
""".
-spec resend_holes(log()) -> log().
resend_holes(#sendlog{ranges = Ranges, una = Una} = Log) ->
    Log1 = Log#sendlog{high_rxt = Una},
    lists:foldl(fun({Start, #sent{rxt = true, sacked = false} = Old}, Acc) ->
                        store(Acc, Start, Old, Old#sent{rxt = false});
                   (_, Acc) -> Acc
                end, Log1, gb_trees:to_list(Ranges)).

-doc """
RFC 6675's `NextSeg` (section 4), searching from `HighRxt`. Rule 1: the first unSACKed range
not yet retransmitted, if it is lost; unlike RFC 6675's condition 1.b it need not lie below
the highest SACKed byte, so NewReno's mark at `snd_una` and a timeout's marks are resent. Rule 2: new data, if the caller allows it. Rule 3: the first unSACKed range not
yet retransmitted, below the highest SACKed byte. Rule 4: the rescue retransmission, one
segment ending at the highest unSACKed byte, once per recovery. Rules 1 and 3 retransmit at
most `Mss` bytes and nothing at or past `recover`. Since the lost ranges are a prefix of the
unSACKed ones, "not yet retransmitted" is RFC 6675's "above HighRxt".
""".
-spec next_seg(log(), next_seg_opts()) -> segment().
next_seg(#sendlog{ranges = Ranges, fack = Fack, high_rxt = HighRxt} = Log,
         #{mss := Mss, recover := Recover, new_data := NewData, rescue := Rescue})
  when is_integer(Mss), Mss > 0, is_integer(Recover), is_boolean(NewData), is_boolean(Rescue) ->
    case first_unretransmitted(gb_trees:next(gb_trees:iterator_from(HighRxt, Ranges))) of
        {Start, #sent{lost = true, next = Next}} when Start < Recover ->
            {retransmit, Start, lists:min([Next, Start + Mss, Recover])};
        _ when NewData ->
            new;
        {Start, #sent{lost = false, next = Next}} when Start < Fack, Start < Recover ->
            {retransmit, Start, lists:min([Next, Start + Mss, Recover])};
        _ when Rescue ->
            rescue_seg(Log, Mss);
        _ ->
            none
    end.

first_unretransmitted({Start, #sent{sacked = false, rxt = false} = Sent, _}) -> {Start, Sent};
first_unretransmitted({_, _, Iter}) -> first_unretransmitted(gb_trees:next(Iter));
first_unretransmitted(none) -> none.

rescue_seg(#sendlog{una = Una, rescue = RescueRxt, ranges = Ranges, high_rxt = HighRxt}, Mss)
  when RescueRxt =:= none; Una > RescueRxt ->
    %% Rule 4 rescues only an unSACKed byte above HighRxt (HighRxt < S2 <= HighData).
    case highest_unsacked(gb_trees:next(gb_trees:iterator(Ranges, reversed))) of
        {Start, Next} when Next > HighRxt -> {rescue, max(Start, Next - Mss), Next};
        _ -> none
    end;
rescue_seg(_, _) ->
    none.

highest_unsacked({Start, #sent{sacked = false, next = Next}, _}) -> {Start, Next};
highest_unsacked({_, _, Iter}) -> highest_unsacked(gb_trees:next(Iter));
highest_unsacked(none) -> none.

-doc "`snd_una`, the first unacknowledged byte.".
-spec snd_una(log()) -> integer().
snd_una(#sendlog{una = Una}) -> Una.
-doc "`snd_max`, the byte after the highest byte sent.".
-spec snd_max(log()) -> integer().
snd_max(#sendlog{max = Max}) -> Max.
-doc "The end of the highest SACKed range, `snd_una` when nothing is SACKed.".
-spec snd_fack(log()) -> integer().
snd_fack(#sendlog{fack = Fack}) -> Fack.
-doc "RFC 6675's pipe: the bytes the sender estimates are in the network.".
-spec pipe(log()) -> non_neg_integer().
pipe(#sendlog{una = Una, max = Max, sacked = Sacked, lost = Lost, rxt = Rxt}) ->
    (Max - Una) - Sacked - Lost + Rxt.
-doc "The bytes sent and not cumulatively acknowledged, `snd_max - snd_una`.".
-spec flight(log()) -> non_neg_integer().
flight(#sendlog{una = Una, max = Max}) -> Max - Una.
-doc "The bytes SACKed above `snd_una`.".
-spec sacked_bytes(log()) -> non_neg_integer().
sacked_bytes(#sendlog{sacked = Sacked}) -> Sacked.
-doc "Every byte sent since the log was made, retransmissions included (PRR's `prr_out` is a difference of two).".
-spec sent_bytes(log()) -> non_neg_integer().
sent_bytes(#sendlog{sent_bytes = Bytes}) -> Bytes.
-doc "Whether the scoreboard holds SACK information, FreeBSD's non-empty `snd_holes`.".
-spec has_holes(log()) -> boolean().
has_holes(#sendlog{sacked = Sacked}) -> Sacked > 0.
-doc "The ranges in order, for tests and the inspector.".
-spec to_list(log()) -> [{integer(), integer(), map()}].
to_list(#sendlog{ranges = Ranges}) ->
    [{Start, Next, #{sent_at => At, transmissions => N, sacked => Sk, lost => L, rxt => R}}
     || {Start, #sent{next = Next, sent_at = At, transmissions = N, sacked = Sk, lost = L, rxt = R}}
            <- gb_trees:to_list(Ranges)].

%% Internal: the one funnel for changing a range, and what it is built from.

count_sent(#sendlog{sent_bytes = Bytes} = Log, N) -> Log#sendlog{sent_bytes = Bytes + N}.

resent(#sent{transmissions = N, sacked = Sacked, rxt = Rxt} = Sent, Now, MarkRxt) ->
    Sent#sent{transmissions = N + 1, sent_at = Now, rxt = Rxt orelse (MarkRxt andalso not Sacked)}.

%% Removes the ranges below Ack and cuts the one containing it.
advance(#sendlog{una = Una} = Log, Ack) when Ack =< Una ->
    Log;
advance(#sendlog{fack = Fack, high_rxt = HighRxt} = Log, Ack) ->
    Log1 = drop_below(Log, Ack),
    Log1#sendlog{una = Ack, fack = max(Fack, Ack), high_rxt = max(HighRxt, Ack)}.

drop_below(#sendlog{ranges = Ranges} = Log, Ack) ->
    case gb_trees:is_empty(Ranges) of
        true ->
            Log;
        false ->
            case gb_trees:smallest(Ranges) of
                {Start, _} when Start >= Ack ->
                    Log;
                {Start, #sent{next = Next} = Old} when Next =< Ack ->
                    drop_below(store(Log, Start, Old, none), Ack);
                {Start, Old} ->
                    store(store(Log, Start, Old, none), Ack, none, Old)
            end
    end.

%% Marks SACKed the ranges a block covers whole, merging each with a SACKed neighbour below,
%% and the range after the block with the block's last.
sack_block({Left, Right}, #sendlog{una = Una, max = Max, ranges = Ranges} = Log)
  when is_integer(Left), is_integer(Right) ->
    From = max(Left, Una),
    To = min(Right, Max),
    case From < To of
        true ->
            Log1 = sack_ranges(gb_trees:next(gb_trees:iterator_from(From, Ranges)), To, Log),
            merge_down(Log1, To);
        false -> Log
    end.

sack_ranges({Start, #sent{next = Next} = Old, Iter}, To, #sendlog{fack = Fack} = Log)
  when Next =< To ->
    Log1 = case Old#sent.sacked of
        true -> Log;
        false -> store(Log, Start, Old, Old#sent{sacked = true, lost = false, rxt = false})
    end,
    sack_ranges(gb_trees:next(Iter), To, merge_down(Log1#sendlog{fack = max(Fack, Next)}, Start));
sack_ranges(_, _, Log) ->
    Log.

%% Merges a SACKed range at Start into a SACKed range just below it.
merge_down(#sendlog{ranges = Ranges} = Log, Start) ->
    case {gb_trees:lookup(Start, Ranges), gb_trees:smaller(Start, Ranges)} of
        {{value, #sent{sacked = true, next = Next, transmissions = N} = Upper},
         {Below, #sent{sacked = true, next = Start, transmissions = M} = Lower}} ->
            store(store(Log, Start, Upper, none), Below, Lower,
                  Lower#sent{next = Next, transmissions = max(N, M)});
        _ ->
            Log
    end.

%% Applies Fun to every range in [From, To), cutting ranges at both ends first.
update(Log0, From, To, Fun) ->
    Log = split(split(Log0, From), To),
    update_ranges(gb_trees:next(gb_trees:iterator_from(From, Log#sendlog.ranges)), To, Fun, Log).

update_ranges({Start, Old, Iter}, To, Fun, Log) when Start < To ->
    update_ranges(gb_trees:next(Iter), To, Fun, store(Log, Start, Old, Fun(Old)));
update_ranges(_, _, _, Log) ->
    Log.

split(#sendlog{ranges = Ranges} = Log, Seq) ->
    case gb_trees:smaller(Seq, Ranges) of
        {Start, #sent{next = Next} = Sent} when Next > Seq ->
            store(store(Log, Start, Sent, Sent#sent{next = Seq}), Seq, none, Sent);
        _ ->
            Log
    end.

%% Replaces the range at Start (none: absent) and keeps the byte counters.
store(#sendlog{ranges = Ranges, sacked = Sk, lost = Lo, rxt = Rx} = Log, Start, Old, New) ->
    {Sk0, Lo0, Rx0} = weight(Start, Old),
    {Sk1, Lo1, Rx1} = weight(Start, New),
    Ranges1 = case {Old, New} of
        {none, _} -> gb_trees:insert(Start, New, Ranges);
        {_, none} -> gb_trees:delete(Start, Ranges);
        _ -> gb_trees:update(Start, New, Ranges)
    end,
    Log#sendlog{ranges = Ranges1, sacked = Sk - Sk0 + Sk1, lost = Lo - Lo0 + Lo1,
                rxt = Rx - Rx0 + Rx1}.

weight(_, none) -> {0, 0, 0};
weight(Start, #sent{next = Next, sacked = true}) -> {Next - Start, 0, 0};
weight(Start, #sent{next = Next, lost = Lost, rxt = Rxt}) ->
    {0, bytes_if(Lost, Next - Start), bytes_if(Rxt, Next - Start)}.

bytes_if(true, N) -> N;
bytes_if(false, _) -> 0.
