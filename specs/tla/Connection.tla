\* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
\* SPDX-License-Identifier: BSD-2-Clause
------------------------------ MODULE Connection ------------------------------
(***************************************************************************)
(* One domain A and two incarnations of a peer node name: domain 1, and    *)
(* domain 2 of the same name, which can start once domain 1 has ended      *)
(* (D2: a name belongs to one live domain at a time).  Connection c joins  *)
(* A and domain c (design-domains.md, Connections, and Introduction and    *)
(* connection down; D9, D16, D17).                                         *)
(*                                                                         *)
(* An abstract protocol model: a lane is a count of frames published and a *)
(* count delivered, in order, and Lane.tla checks the mechanism beneath.   *)
(* Only the peer's lane to A is modelled: nothing checked here depends on  *)
(* what A writes to the peer.                                             *)
(*                                                                         *)
(* The domain service builds a connection's objects, tells the peer        *)
(* connection_up and queues the control records about the peer name for A *)
(* (connection_up, connection_down).  It sends A one at a time, each once  *)
(* A answered the last, and sends a later domain's connection_up only once *)
(* the earlier connection is closing and its connection_down has gone      *)
(* out.  It tells the peer connection_down once the peer has answered its  *)
(* connection_up, and deletes a connection's objects only once each party  *)
(* has answered connection_unmapped or connection_lost, or ended.          *)
(*                                                                         *)
(* A connection ends when the peer ends, when either runtime ends it       *)
(* itself (a malformed frame, disconnect_node), or by the service's        *)
(* policy, which may close it while the peer is still writing.  A, told    *)
(* connection_down, drains the lane to the wpos it reads then, fires its   *)
(* links and monitors, unmaps and answers connection_unmapped.  A message  *)
(* to the service arrives in the step that sends it, so the service reads  *)
(* A's answer from conn and the peer's from pans.  The service's records   *)
(* to A wait in ctl; to the peer it sends one connection_up and at most    *)
(* one connection_down, kept as pup and pdown.                             *)
(*                                                                         *)
(* Fault seeds one defect: "no_drain" (A fires before draining),           *)
(* "early_delete" (deletion once the peer ended, without A's answer),      *)
(* "no_gate" (records sent without waiting for A's answer),                *)
(* "early_answer" (A answers connection_unmapped before it drains and      *)
(* unmaps), "wait_for_peer" (A drains to the peer's last frame, which an   *)
(* ended peer may never write), "early_name" (the service's queue is plain *)
(* FIFO, so a later domain's connection_up can overtake the earlier        *)
(* connection's connection_down), "wait_for_unmap" (A answers only once    *)
(* the peer has let go), "stray_answer" (A answers a record when it ends a *)
(* connection itself), "read_after_down" (A goes on delivering after its   *)
(* down).                                                                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Frames, Fault

Faults == {"none", "no_drain", "early_delete", "no_gate", "early_answer",
           "wait_for_peer", "early_name", "wait_for_unmap", "stray_answer",
           "read_after_down"}

ASSUME Frames \in Nat \ {0} /\ Fault \in Faults

Conns == {1, 2}
Reasons == {"domain_down", "noconnection"}
Records == {<<"up", c>> : c \in Conns}
           \cup {<<"down", c, r>> : c \in Conns, r \in Reasons}

VARIABLES
    peer,       \* peer domain c: "unborn", "alive" or "ended"
    ds,         \* the service's record of c: "none", "up", "closing",
                \* "deleted"; c's objects exist while it is "up" or "closing"
    dsq,        \* records about the peer name waiting to go to A
    ctl,        \* records sent to A, not yet read
    owed,       \* records sent to A that A has not answered
    conn,       \* A's view of c: "none", "mapped", "draining", "gone" (A
                \* answered connection_unmapped) or "lost" (A ended c itself
                \* and told the service connection_lost)
    pup,        \* the service told peer c connection_up
    pdown,      \* the service told peer c connection_down
    pans,       \* peer c's last answer: "none", "mapped", "unmapped", "lost"
    sent,       \* frames peer c published on the lane to A
    deliv,      \* frames A delivered from that lane
    drainto,    \* the wpos A read when told connection_down
    why,        \* the reason A was given: "none" or one of Reasons
    alog        \* A's deliveries and downs, in order

vars == <<peer, ds, dsq, ctl, owed, conn, pup, pdown, pans, sent, deliv,
          drainto, why, alog>>

\* Who maps c's objects.  A maps from its connection_up until it unmaps; a
\* peer from its connection_mapped until it unmaps or ends.
Live(c) == ds[c] \in {"up", "closing"}
AMaps(c) == conn[c] \in {"mapped", "draining"}
PMaps(c) == peer[c] = "alive" /\ pans[c] = "mapped"

Init ==
    /\ peer = [c \in Conns |-> IF c = 1 THEN "alive" ELSE "unborn"]
    /\ ds = [c \in Conns |-> "none"]
    /\ dsq = <<>> /\ ctl = <<>> /\ owed = 0
    /\ conn = [c \in Conns |-> "none"]
    /\ pup = [c \in Conns |-> FALSE] /\ pdown = [c \in Conns |-> FALSE]
    /\ pans = [c \in Conns |-> "none"]
    /\ sent = [c \in Conns |-> 0] /\ deliv = [c \in Conns |-> 0]
    /\ drainto = [c \in Conns |-> 0]
    /\ why = [c \in Conns |-> "none"]
    /\ alog = <<>>

-----------------------------------------------------------------------------
(* The domain service. *)

\* Build c's objects as one plan, tell the peer connection_up and queue
\* connection_up for A.
Introduce(c) ==
    /\ peer[c] = "alive" /\ ds[c] = "none"
    /\ ds' = [ds EXCEPT ![c] = "up"]
    /\ dsq' = Append(dsq, <<"up", c>>)
    /\ pup' = [pup EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<peer, ctl, owed, conn, pdown, pans, sent, deliv, drainto,
                   why, alog>>

\* Mark c closing and queue connection_down for A, unless A ended c itself;
\* the reason is domain_down when the peer has ended.
Closing(c) ==
    /\ ds' = [ds EXCEPT ![c] = "closing"]
    /\ dsq' = IF conn[c] = "lost" THEN dsq
              ELSE Append(dsq, <<"down", c,
                                 IF peer[c] = "ended" THEN "domain_down"
                                 ELSE "noconnection">>)
    /\ UNCHANGED <<peer, ctl, owed, conn, pup, pdown, pans, sent, deliv,
                   drainto, why, alog>>

\* The peer's end, learnt through the fault gate, or connection_lost from
\* either party.
Close(c) ==
    /\ ds[c] = "up"
    /\ peer[c] = "ended" \/ conn[c] = "lost" \/ pans[c] = "lost"
    /\ Closing(c)

\* A policy decision closes a live connection; the peer may go on writing
\* until it reads its connection_down.  The service may or may not take it.
Policy(c) == ds[c] = "up" /\ peer[c] = "alive" /\ Closing(c)

RemoveAt(s, i) == SubSeq(s, 1, i - 1) \o SubSeq(s, i + 1, Len(s))

\* dsq[i] may go next: no record of its own connection or an older one is
\* queued ahead of it, and every older connection is closing or gone, so
\* its connection_down, if A is owed one, has gone out before.
InTurn(i) ==
    LET c == dsq[i][2]
    IN /\ ~\E j \in 1..Len(dsq) : dsq[j][2] < c \/ (dsq[j][2] = c /\ j < i)
       /\ \A e \in Conns : e < c => ds[e] # "up"

\* Send A the next record about the peer name once it answered the last.
Send ==
    /\ owed = 0 \/ Fault = "no_gate"
    /\ \E i \in 1..Len(dsq) :
        /\ IF Fault = "early_name" THEN i = 1 ELSE InTurn(i)
        /\ ctl' = Append(ctl, dsq[i])
        /\ dsq' = RemoveAt(dsq, i)
    /\ owed' = owed + 1
    /\ UNCHANGED <<peer, ds, conn, pup, pdown, pans, sent, deliv, drainto, why,
                   alog>>

\* Tell the peer connection_down once it answered its connection_up and
\* has not ended the connection itself.
TellPeer(c) ==
    /\ ds[c] = "closing" /\ pans[c] = "mapped" /\ ~pdown[c]
    /\ pdown' = [pdown EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<peer, ds, dsq, ctl, owed, conn, pup, pans, sent, deliv,
                   drainto, why, alog>>

\* A let go of c: it answered connection_unmapped or connection_lost.
ALetGo(c) == \/ conn[c] \in {"gone", "lost"}
             \/ Fault = "early_answer" /\ why[c] # "none"
PeerLetGo(c) == peer[c] = "ended" \/ pans[c] \in {"unmapped", "lost"}

\* Delete c's objects once each party has let go or ended.
Delete(c) ==
    /\ ds[c] = "closing"
    /\ IF Fault = "early_delete" THEN peer[c] = "ended" \/ ALetGo(c)
       ELSE ALetGo(c) /\ PeerLetGo(c)
    /\ ds' = [ds EXCEPT ![c] = "deleted"]
    /\ UNCHANGED <<peer, dsq, ctl, owed, conn, pup, pdown, pans, sent, deliv,
                   drainto, why, alog>>

DS == Send \/ \E c \in Conns : Introduce(c) \/ Close(c) \/ TellPeer(c)
                               \/ Delete(c)

-----------------------------------------------------------------------------
(* Domain A, the survivor: its connection agent and its lane ports. *)

\* connection_up: map and answer connection_mapped.
ReadUp ==
    /\ ctl # <<>> /\ Head(ctl)[1] = "up"
    /\ conn' = [conn EXCEPT ![Head(ctl)[2]] = "mapped"]
    /\ ctl' = Tail(ctl) /\ owed' = owed - 1
    /\ UNCHANGED <<peer, ds, dsq, pup, pdown, pans, sent, deliv, drainto, why,
                   alog>>

\* connection_down: read the lane's wpos once and start the drain.
ReadDown ==
    /\ ctl # <<>> /\ Head(ctl)[1] = "down" /\ conn[Head(ctl)[2]] # "lost"
    /\ LET c == Head(ctl)[2] IN
        /\ conn' = [conn EXCEPT ![c] = "draining"]
        /\ drainto' = [drainto EXCEPT ![c] =
                          IF Fault = "wait_for_peer" THEN Frames ELSE sent[c]]
        /\ why' = [why EXCEPT ![c] = Head(ctl)[3]]
    /\ ctl' = Tail(ctl)
    /\ owed' = IF Fault = "early_answer" THEN owed - 1 ELSE owed
    /\ UNCHANGED <<peer, ds, dsq, pup, pdown, pans, sent, deliv, alog>>

\* connection_down for a connection A has ended itself: A unmapped it
\* then, so it answers connection_unmapped at once.
ReadDownLost ==
    /\ ctl # <<>> /\ Head(ctl)[1] = "down" /\ conn[Head(ctl)[2]] = "lost"
    /\ ctl' = Tail(ctl) /\ owed' = owed - 1
    /\ UNCHANGED <<peer, ds, dsq, conn, pup, pdown, pans, sent, deliv, drainto,
                   why, alog>>

\* The funnel delivers the next frame, never past the drain's position.
Deliver(c) ==
    /\ \/ AMaps(c)
       \/ Fault = "read_after_down" /\ conn[c] = "gone"
    /\ deliv[c] < sent[c]
    /\ conn[c] = "draining" => deliv[c] < drainto[c]
    /\ deliv' = [deliv EXCEPT ![c] = deliv[c] + 1]
    /\ alog' = Append(alog, <<"frame", c, deliv[c] + 1>>)
    /\ UNCHANGED <<peer, ds, dsq, ctl, owed, conn, pup, pdown, pans, sent,
                   drainto, why>>

\* Drained: fire links and monitors, unmap, answer connection_unmapped.
FinishDown(c) ==
    /\ conn[c] = "draining"
    /\ Fault = "no_drain" \/ deliv[c] = drainto[c]
    /\ Fault = "wait_for_unmap" => PeerLetGo(c)
    /\ conn' = [conn EXCEPT ![c] = "gone"]
    /\ alog' = Append(alog, <<"down", c>>)
    /\ owed' = IF Fault = "early_answer" THEN owed ELSE owed - 1
    /\ UNCHANGED <<peer, ds, dsq, ctl, pup, pdown, pans, sent, deliv, drainto,
                   why>>

A == ReadUp \/ ReadDown \/ ReadDownLost
     \/ \E c \in Conns : Deliver(c) \/ FinishDown(c)

\* A finds a malformed frame: it stops reading, fires its links and
\* monitors with noconnection, unmaps and tells the service connection_lost.
ALose(c) ==
    /\ conn[c] = "mapped"
    /\ conn' = [conn EXCEPT ![c] = "lost"]
    /\ alog' = Append(alog, <<"down", c>>)
    /\ owed' = IF Fault = "stray_answer" THEN owed - 1 ELSE owed
    /\ UNCHANGED <<peer, ds, dsq, ctl, pup, pdown, pans, sent, deliv, drainto,
                   why>>

-----------------------------------------------------------------------------
(* The peers.  Each step reads only the peer's own state and the records *)
(* the service sent it. *)

\* connection_up: map and answer connection_mapped.
PMap(c) ==
    /\ peer[c] = "alive" /\ pup[c] /\ pans[c] = "none"
    /\ pans' = [pans EXCEPT ![c] = "mapped"]
    /\ UNCHANGED <<peer, ds, dsq, ctl, owed, conn, pup, pdown, sent, deliv,
                   drainto, why, alog>>

PWrite(c) ==
    /\ PMaps(c) /\ sent[c] < Frames
    /\ sent' = [sent EXCEPT ![c] = sent[c] + 1]
    /\ UNCHANGED <<peer, ds, dsq, ctl, owed, conn, pup, pdown, pans, deliv,
                   drainto, why, alog>>

\* The peer's runtime ends c itself: it stops writing, unmaps, and tells
\* the service connection_lost.
PLose(c) ==
    /\ PMaps(c)
    /\ pans' = [pans EXCEPT ![c] = "lost"]
    /\ UNCHANGED <<peer, ds, dsq, ctl, owed, conn, pup, pdown, sent, deliv,
                   drainto, why, alog>>

\* connection_down: the peer drains, unmaps and answers connection_unmapped.
PUnmap(c) ==
    /\ PMaps(c) /\ pdown[c]
    /\ pans' = [pans EXCEPT ![c] = "unmapped"]
    /\ UNCHANGED <<peer, ds, dsq, ctl, owed, conn, pup, pdown, sent, deliv,
                   drainto, why, alog>>

\* The kernel posts the exit record only once no thread of the domain can
\* run, so the peer's sent count is final from here on; its space and its
\* mappings are gone with it.
PEnd(c) ==
    /\ peer[c] = "alive"
    /\ peer' = [peer EXCEPT ![c] = "ended"]
    /\ UNCHANGED <<ds, dsq, ctl, owed, conn, pup, pdown, pans, sent, deliv,
                   drainto, why, alog>>

\* A later domain of the same node name starts once the first has ended.
PStart ==
    /\ peer[1] = "ended" /\ peer[2] = "unborn"
    /\ peer' = [peer EXCEPT ![2] = "alive"]
    /\ UNCHANGED <<ds, dsq, ctl, owed, conn, pup, pdown, pans, sent, deliv,
                   drainto, why, alog>>

-----------------------------------------------------------------------------

\* Steps A and the service owe, which fairness covers.  Each of the two
\* can take only finitely many steps, so weak fairness of each as a whole
\* makes every step it keeps enabled happen.  Nothing a peer does or omits
\* is owed: A drains waiting on nothing the peer would have to do.
Owed == DS \/ A

\* Steps the environment, the peers and policy may take or never take.
Choice == PStart \/ \E c \in Conns : Policy(c) \/ ALose(c) \/ PMap(c)
                                     \/ PWrite(c)
                                     \/ PLose(c) \/ PUnmap(c) \/ PEnd(c)

\* Settled on A's and the service's side: nothing queued or owed to A or
\* to the peer, every frame of an up connection delivered, and A done with
\* every connection the service closed.  Deletion also needs the peer's
\* unmap or end, which is the peer's choice, so it is not part of this.
Settled ==
    /\ dsq = <<>> /\ ctl = <<>> /\ owed = 0
    /\ \A c \in Conns :
        /\ ds[c] = "up" => conn[c] = "mapped" /\ deliv[c] = sent[c]
        /\ peer[c] = "ended" => ds[c] # "up"
        /\ ds[c] \in {"closing", "deleted"} => conn[c] \in {"gone", "lost"}
        /\ ds[c] = "closing" /\ pans[c] = "mapped" => pdown[c]

\* The one acceptable terminal state: both peers have ended, A and the
\* service have settled, and every connection's objects are deleted.
Finished ==
    /\ Settled
    /\ \A c \in Conns : peer[c] = "ended" /\ ds[c] \in {"none", "deleted"}
    /\ UNCHANGED vars

Next == Owed \/ Choice \/ Finished

Fairness == WF_vars(DS) /\ WF_vars(A)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties. *)

TypeOK ==
    /\ peer \in [Conns -> {"unborn", "alive", "ended"}]
    /\ ds \in [Conns -> {"none", "up", "closing", "deleted"}]
    /\ dsq \in Seq(Records) /\ ctl \in Seq(Records)
    /\ owed \in Nat
    /\ conn \in [Conns -> {"none", "mapped", "draining", "gone", "lost"}]
    /\ pup \in [Conns -> BOOLEAN] /\ pdown \in [Conns -> BOOLEAN]
    /\ pans \in [Conns -> {"none", "mapped", "unmapped", "lost"}]
    /\ sent \in [Conns -> 0..Frames] /\ deliv \in [Conns -> 0..Frames]
    /\ drainto \in [Conns -> 0..Frames]
    /\ why \in [Conns -> {"none"} \cup Reasons]
    /\ alog \in Seq({<<"frame", c, n>> : c \in Conns, n \in 1..Frames}
                    \cup {<<"down", c>> : c \in Conns})

\* D17: A acts on a peer's end only after every frame the peer published.
EndedPeerDrained ==
    \A c \in Conns : conn[c] = "gone" /\ why[c] = "domain_down"
                     => deliv[c] = sent[c]

\* Nothing of a connection is delivered after A's down for it, and its
\* frames arrive in the order sent.
OrderedThenDown ==
    \A i, j \in 1..Len(alog) :
        /\ i < j /\ alog[i] = <<"down", alog[i][2]>>
               => alog[j][2] # alog[i][2]
        /\ i < j /\ alog[i][1] = "frame" /\ alog[j][1] = "frame"
           /\ alog[i][2] = alog[j][2] => alog[i][3] < alog[j][3]

\* D16: no party maps a deleted object, so a runtime that answered
\* connection_unmapped never touched a deleted page.
NoUseAfterDelete == \A c \in Conns : AMaps(c) \/ PMaps(c) => Live(c)

\* At most one control record per peer name is outstanding, which the
\* reserve of A's lane from the system domain holds.
OneControlRecord == owed <= 1

\* A never has two connections up for the one peer name: the later
\* connection_up never reaches A while its entry for the name is up.
OneEntry == Cardinality({c \in Conns : AMaps(c)}) <= 1

\* Progress: A and the service settle, whatever the peers do or omit.
Settles == <>[]Settled

\* Reachability witness: the later incarnation's connection reaches A.
LaterNeverUp == ~(conn[1] \in {"gone", "lost"} /\ conn[2] = "mapped")
=============================================================================
