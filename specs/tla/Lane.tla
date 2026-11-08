\* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
\* SPDX-License-Identifier: BSD-2-Clause
--------------------------------- MODULE Lane ---------------------------------
(***************************************************************************)
(* One lane of a connection (design-domains.md, Connections): a producer   *)
(* writes records into a ring of Size units and publishes wpos; a consumer *)
(* copies them out, publishing rpos behind what it copied.  Each party     *)
(* waits only on its own bell.  A waiter stores the position it waits for  *)
(* (the consumer's wake, the producer's need), fences, and loads the other *)
(* party's position once more; a mover stores its position, fences, loads *)
(* the waited-for position and rings only if its store crossed it.         *)
(*                                                                         *)
(* This is a mechanism model: every load and store of a shared word is a   *)
(* step of its own, so the other party can act between them.  Interleaving *)
(* is sequentially consistent; a missing fence is modelled as the load     *)
(* that follows the store being performed before it, which is the one      *)
(* reordering a full fence forbids here.  Hardware ordering itself is      *)
(* herd7's to check.  A position counts 16-byte units, not bytes, so wake  *)
(* is rpos + 1 unit; a record is one header unit and Lens[i] body units.   *)
(*                                                                         *)
(* Fault seeds one defect: "wpos_fence", "wake_fence", "rpos_fence" or     *)
(* "need_fence" drops the fence after that store; "room" lets the producer *)
(* count one unit more room than the lane has; "strict_crossing" rings     *)
(* only when a store moves strictly past the waited-for position;         *)
(* "ring_always" rings after every store.                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Size, Lens, Fault

Faults == {"none", "wpos_fence", "wake_fence", "rpos_fence", "need_fence",
           "room", "strict_crossing", "ring_always"}

ASSUME Size \in Nat \ {0} /\ Lens \in Seq(Nat) /\ Fault \in Faults

\* The configurations' record bodies: one empty record, one longer than an
\* eight-unit lane, so it is written and read in parts across the wrap, and
\* one short record behind it.
Records == <<0, 9, 1>>

Min(a, b) == IF a < b THEN a ELSE b
Max(s) == CHOOSE m \in s : \A n \in s : n <= m

\* The units the producer writes, in order: <<record, offset>>, offset 0
\* being the record's header.
RECURSIVE UnitsFrom(_)
UnitsFrom(i) == IF i > Len(Lens) THEN <<>>
                ELSE [k \in 1..(Lens[i] + 1) |-> <<i, k - 1>>] \o UnitsFrom(i + 1)
Stream == UnitsFrom(1)
Total == Len(Stream)
Empty == <<0, 0>>

\* What a producer at w waits for: room for the rest of the record, or for a
\* quarter of the lane, whichever is less.
Quarter == IF Size \div 4 = 0 THEN 1 ELSE Size \div 4
RestOf(w) == Lens[Stream[w + 1][1]] + 1 - Stream[w + 1][2]
Want(w) == Min(RestOf(w), Quarter)

\* A store moving a position from b to a crossed the waited-for position x.
Crossed(b, a, x) == CASE Fault = "ring_always" -> TRUE
                      [] Fault = "strict_crossing" -> b < x /\ x < a
                      [] OTHER -> b < x /\ x <= a

VARIABLES
    cells,      \* the data area, Size units
    wpos,       \* ring header: units published, release-stored
    need,       \* ring header: the consumer position the producer waits for
    rpos,       \* reader page: units consumed, release-stored
    wake,       \* reader page: the producer position the consumer waits for
    pbell,      \* the producer's bell has a pending trigger
    cbell,      \* the consumer's bell has a pending trigger
    ppc,        \* the producer's next step: "write" (store units, or
                \* find the room short), "ring" (fence, load wake, ring
                \* if crossed), "recheck" (fence, load rpos again),
                \* "park" (wait on its bell), "done" (all written);
                \* "store" and "need" only in the unfenced faults, after
                \* the early load, before the store
    cpc,        \* the consumer's next step: "read" (copy units, or
                \* find none and store wake), "ring", "recheck",
                \* "park"; "copy" and "wake" only in the unfenced
                \* faults, after the early load, before the store
    pold,       \* wpos before the producer's last store
    cold,       \* rpos before the consumer's last store
    pseen,      \* a value the producer loaded early (unfenced faults only)
    cseen,      \* a value the consumer loaded early (unfenced faults only)
    got,        \* every unit the consumer copied out, in order
    wakeopen,   \* ghost: wakes stored that no producer ring answered
    needopen    \* ghost: needs stored that no consumer ring answered

vars == <<cells, wpos, need, rpos, wake, pbell, cbell, ppc, cpc, pold, cold,
          pseen, cseen, got, wakeopen, needopen>>

Init ==
    /\ cells = [j \in 0..(Size - 1) |-> Empty]
    /\ wpos = 0 /\ need = 0 /\ rpos = 0 /\ wake = 0
    /\ pbell = FALSE /\ cbell = FALSE
    /\ ppc = "write" /\ cpc = "read"
    /\ pold = 0 /\ cold = 0 /\ pseen = 0 /\ cseen = 0
    /\ got = <<>>
    /\ wakeopen = 0 /\ needopen = 0

-----------------------------------------------------------------------------
(* The producer. *)

\* The room the producer computes from its acquire load of rpos.
Room == Size - (wpos - rpos) + (IF Fault = "room" THEN 1 ELSE 0)

\* Without the fence after the store of wpos, the load of wake is done first.
PLoadWakeEarly ==
    /\ Fault = "wpos_fence" /\ ppc = "write" /\ wpos < Total /\ Room >= 1
    /\ pseen' = wake /\ ppc' = "store"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, cpc, pold,
                   cold, cseen, got, wakeopen, needopen>>

\* Write k units of the current record into the room, then release-store wpos.
PStore ==
    /\ ppc = IF Fault = "wpos_fence" THEN "store" ELSE "write"
    /\ wpos < Total /\ Room >= 1
    /\ \E k \in 1..Min(Room, RestOf(wpos)) :
        /\ cells' = [j \in DOMAIN cells |->
                        LET ms == {m \in wpos..(wpos + k - 1) : m % Size = j}
                        IN IF ms = {} THEN cells[j] ELSE Stream[Max(ms) + 1]]
        /\ wpos' = wpos + k
    /\ pold' = wpos /\ ppc' = "ring"
    /\ UNCHANGED <<need, rpos, wake, pbell, cbell, cpc, cold, pseen, cseen,
                   got, wakeopen, needopen>>

\* Fence, load wake, ring the consumer only if the store crossed it.
PRing ==
    /\ ppc = "ring"
    /\ LET w == IF Fault = "wpos_fence" THEN pseen ELSE wake
           rung == Crossed(pold, wpos, w)
       IN /\ cbell' = (cbell \/ rung)
          /\ wakeopen' = IF rung THEN wakeopen - 1 ELSE wakeopen
    /\ ppc' = "write"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cpc, pold, cold,
                   pseen, cseen, got, needopen>>

\* Without the fence after the store of need, the load of rpos is done first.
PLoadRposEarly ==
    /\ Fault = "need_fence" /\ ppc = "write" /\ wpos < Total
    /\ Room < Want(wpos)
    /\ pseen' = rpos /\ ppc' = "need"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, cpc, pold,
                   cold, cseen, got, wakeopen, needopen>>

\* The record does not fit: publish need = wpos + want - size.
PStoreNeed ==
    /\ ppc = IF Fault = "need_fence" THEN "need" ELSE "write"
    /\ wpos < Total /\ (Fault = "need_fence" \/ Room < Want(wpos))
    /\ need' = wpos + Want(wpos) - Size
    /\ ppc' = IF Fault = "need_fence"
              THEN IF Size - (wpos - pseen) >= Want(wpos) THEN "write" ELSE "park"
              ELSE "recheck"
    /\ needopen' = needopen + 1
    /\ UNCHANGED <<cells, wpos, rpos, wake, pbell, cbell, cpc, pold, cold,
                   pseen, cseen, got, wakeopen>>

\* Fence, load rpos once more, and park only if the room is still short.
PRecheck ==
    /\ ppc = "recheck"
    /\ ppc' = IF Size - (wpos - rpos) >= Want(wpos) THEN "write" ELSE "park"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, cpc, pold,
                   cold, pseen, cseen, got, wakeopen, needopen>>

PWake ==
    /\ ppc = "park" /\ pbell
    /\ pbell' = FALSE /\ ppc' = "write"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, cbell, cpc, pold, cold,
                   pseen, cseen, got, wakeopen, needopen>>

PDone ==
    /\ ppc = "write" /\ wpos = Total
    /\ ppc' = "done"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, cpc, pold,
                   cold, pseen, cseen, got, wakeopen, needopen>>

Producer == PLoadWakeEarly \/ PStore \/ PRing \/ PLoadRposEarly \/ PStoreNeed
            \/ PRecheck \/ PWake \/ PDone

-----------------------------------------------------------------------------
(* The consumer. *)

\* Without the fence after the store of rpos, the load of need is done first.
CLoadNeedEarly ==
    /\ Fault = "rpos_fence" /\ cpc = "read" /\ rpos < wpos
    /\ cseen' = need /\ cpc' = "copy"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, ppc, pold,
                   cold, pseen, got, wakeopen, needopen>>

\* Acquire-load wpos, copy k published units out, release-store rpos.
CCopy ==
    /\ cpc = IF Fault = "rpos_fence" THEN "copy" ELSE "read"
    /\ rpos < wpos
    /\ \E k \in 1..(wpos - rpos) :
        /\ got' = got \o [i \in 1..k |-> cells[(rpos + i - 1) % Size]]
        /\ rpos' = rpos + k
    /\ cold' = rpos /\ cpc' = "ring"
    /\ UNCHANGED <<cells, wpos, need, wake, pbell, cbell, ppc, pold, pseen,
                   cseen, wakeopen, needopen>>

\* Fence, load need, ring the producer only if the store crossed it.
CRing ==
    /\ cpc = "ring"
    /\ LET n == IF Fault = "rpos_fence" THEN cseen ELSE need
           rung == Crossed(cold, rpos, n)
       IN /\ pbell' = (pbell \/ rung)
          /\ needopen' = IF rung THEN needopen - 1 ELSE needopen
    /\ cpc' = "read"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, cbell, ppc, pold, cold,
                   pseen, cseen, got, wakeopen>>

\* Without the fence after the store of wake, the load of wpos is done first.
CLoadWposEarly ==
    /\ Fault = "wake_fence" /\ cpc = "read" /\ rpos = wpos
    /\ cseen' = wpos /\ cpc' = "wake"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, ppc, pold,
                   cold, pseen, got, wakeopen, needopen>>

\* Nothing to read: publish wake = rpos + 1.
CStoreWake ==
    /\ cpc = IF Fault = "wake_fence" THEN "wake" ELSE "read"
    /\ (Fault = "wake_fence" \/ rpos = wpos)
    /\ wake' = rpos + 1
    /\ cpc' = IF Fault = "wake_fence"
              THEN IF cseen > rpos THEN "read" ELSE "park"
              ELSE "recheck"
    /\ wakeopen' = wakeopen + 1
    /\ UNCHANGED <<cells, wpos, need, rpos, pbell, cbell, ppc, pold, cold,
                   pseen, cseen, got, needopen>>

\* Fence, load wpos once more, and park only if there is still nothing.
CRecheck ==
    /\ cpc = "recheck"
    /\ cpc' = IF wpos > rpos THEN "read" ELSE "park"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, cbell, ppc, pold,
                   cold, pseen, cseen, got, wakeopen, needopen>>

CWake ==
    /\ cpc = "park" /\ cbell
    /\ cbell' = FALSE /\ cpc' = "read"
    /\ UNCHANGED <<cells, wpos, need, rpos, wake, pbell, ppc, pold, cold,
                   pseen, cseen, got, wakeopen, needopen>>

Consumer == CLoadNeedEarly \/ CCopy \/ CRing \/ CLoadWposEarly \/ CStoreWake
            \/ CRecheck \/ CWake

-----------------------------------------------------------------------------

Quiescent == /\ (ppc = "done" \/ (ppc = "park" /\ ~pbell))
             /\ cpc = "park" /\ ~cbell
Delivered == ppc = "done" /\ got = Stream

\* Every record delivered and both parties at rest: the one terminal state.
Finished == Quiescent /\ Delivered /\ UNCHANGED vars

Next == Producer \/ Consumer \/ Finished

\* Neither party is starved of steps it can take; triggers are not assumed.
Fairness == WF_vars(Producer) /\ WF_vars(Consumer)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties. *)

TypeOK ==
    /\ cells \in [0..(Size - 1) -> {Empty} \cup {Stream[i] : i \in 1..Total}]
    /\ wpos \in 0..Total /\ rpos \in 0..Total
    /\ pbell \in BOOLEAN /\ cbell \in BOOLEAN
    /\ ppc \in {"write", "store", "ring", "need", "recheck", "park", "done"}
    /\ cpc \in {"read", "copy", "ring", "wake", "recheck", "park"}

\* rpos never passes wpos.
ReadBehindWrite == rpos <= wpos

\* The producer never writes over a unit the consumer has not copied.
NoOverwrite == wpos - rpos <= Size

\* What the consumer copied, in parts, is what the producer wrote.
WholeRecords == got = SubSeq(Stream, 1, Len(got))

\* No wait is lost: both parties at rest only once every record is through.
NoLostWait == Quiescent => Delivered

\* A party rings only when its store crossed a position the other party
\* stored and waits for, so at most once for each wait stored.
RingOnlyOnCrossing == wakeopen >= 0 /\ needopen >= 0

\* Every record written is eventually copied out.
Progress == <>(got = Stream)

\* Reachability witness: a parked producer is rung by the consumer's rpos.
ProducerNeverRung == ~(ppc = "park" /\ pbell)
=============================================================================
