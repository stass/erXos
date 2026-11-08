\* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
\* SPDX-License-Identifier: BSD-2-Clause
-------------------------------- MODULE Links --------------------------------
(***************************************************************************)
(* Links, monitors and exits between three domains (design-domains.md,     *)
(* Links, monitors and exits; Introduction and connection down; D9, D17).  *)
(* Domain d runs one process, also named d.  Each ordered pair of domains  *)
(* has a lane, a FIFO of frames.  Each runtime keeps its own process's     *)
(* links and monitors.  An answer about a process q is a link exit or      *)
(* DOWN that q's runtime writes behind everything q sent (q's death, or    *)
(* noproc for a link or monitor of a dead or unexported q), or the         *)
(* noconnection or domain_down that the holder's own runtime fires when    *)
(* the connection goes down.  Exits are trapped, so an answer is a message *)
(* to its holder.                                                          *)
(*                                                                         *)
(* An abstract protocol model: a frame is one step into a lane and one     *)
(* step out of it; Lane.tla checks the lane, Connection.tla the control    *)
(* records, and here a connection's end reaches each party in one step.    *)
(* Each frame carries a stamp: for a message, its number among the         *)
(* messages its sender sent that receiver; for an answer about q, how many *)
(* messages q had sent the holder when the answer was made.  Any runtime   *)
(* may also write a forged answer about another domain's process.          *)
(*                                                                         *)
(* Fault seeds one defect: "fire_before_drain" (the holder fires a dead    *)
(* domain's relations before draining its lane), "any_lane" (the receiver  *)
(* accepts an answer about a process from another domain's lane),          *)
(* "answer_first" (a target's runtime puts noproc ahead of what is queued  *)
(* on the lane), "no_noproc" (a link or monitor of a dead or unexported    *)
(* process is dropped, as a message to it is), "noproc_on_link" (a target  *)
(* that lacks the right answers noproc even when it already holds a link   *)
(* with the sender, which ends the sender's half and leaves its own),      *)
(* "silent_fire" (a connection's end drops its relations unanswered).     *)
(*                                                                         *)
(* Budget bounds the initiating steps; it is a constant of the model, not  *)
(* a TLC state constraint, so TLC explores every behaviour of the bounded  *)
(* model and the roster reports the scope as finite.                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Budget, Exported, Fault

Doms == {1, 2, 3}
Faults == {"none", "fire_before_drain", "any_lane", "answer_first", "no_noproc",
           "noproc_on_link", "silent_fire"}

ASSUME /\ Budget \in Nat /\ Exported \subseteq Doms \X Doms
       /\ Fault \in Faults

\* The configurations' exports: <<h, t>> means domain h holds link and
\* monitor on process t.  Process 3 is exported to nobody; 3 holds them on
\* 1, and 2 and 3 hold nothing on each other.  So 3 may link 1 while 1
\* lacks link on 3: 1's link(3) is answered noproc unless 3 has already
\* linked 1.
Exports == {<<1, 2>>, <<2, 1>>, <<3, 1>>}

\* The one-way pair alone: 2 may link 1, and 1 holds nothing on 2.
OneWay == {<<2, 1>>}

Pairs == {<<s, r>> \in Doms \X Doms : s # r}

VARIABLES
    lane,       \* lane[<<s, r>>]: frames from domain s to domain r
    alive,      \* process d is alive
    up,         \* domain d is running
    view,       \* view[<<d, e>>]: d's connection to e: "up", "draining", "down"
    links,      \* links[p]: the processes p's runtime holds a link with
    mons,       \* mons[p]: the processes p monitors
    watched,    \* watched[q]: the processes monitoring q, kept by q's runtime
    nsent,      \* nsent[<<q, p>>]: messages q has sent p
    got,        \* got[p]: what p received, <<"msg"|"answer", about, stamp>>
    budget      \* the initiating steps left

vars == <<lane, alive, up, view, links, mons, watched, nsent, got, budget>>

Init ==
    /\ lane = [x \in Pairs |-> <<>>]
    /\ alive = [d \in Doms |-> TRUE] /\ up = [d \in Doms |-> TRUE]
    /\ view = [x \in Pairs |-> "up"]
    /\ links = [d \in Doms |-> {}] /\ mons = [d \in Doms |-> {}]
    /\ watched = [d \in Doms |-> {}]
    /\ nsent = [x \in Pairs |-> 0]
    /\ got = [d \in Doms |-> <<>>]
    /\ budget = Budget

\* Lanes with the frames q's runtime writes at q's death: a link exit to
\* each linked process and a DOWN to each monitor, behind what q sent.
DeathLanes(q, L) ==
    [x \in Pairs |->
        IF x[1] = q /\ view[x] = "up"
        THEN L[x] \o (IF x[2] \in links[q]
                      THEN <<<<"exit", q, x[2], nsent[x]>>>> ELSE <<>>)
                  \o (IF x[2] \in watched[q]
                      THEN <<<<"down", q, x[2], nsent[x]>>>> ELSE <<>>)
        ELSE L[x]]

\* p's answers about q when p's runtime fires its relations with q.
Fired(p, q) ==
    IF Fault = "silent_fire" THEN <<>> ELSE
    (IF q \in links[p] THEN <<<<"answer", q, nsent[<<q, p>>]>>>> ELSE <<>>)
    \o (IF q \in mons[p] THEN <<<<"answer", q, nsent[<<q, p>>]>>>> ELSE <<>>)

-----------------------------------------------------------------------------
(* Initiating steps: what processes and domains choose to do. *)

Initiate(p, q, kind) ==
    /\ budget > 0 /\ alive[p] /\ p # q /\ view[<<p, q>>] = "up"
    \* A link to a process already linked, or a second monitor of one, is a
    \* no-op here: relations are sets, one per pair and kind.
    /\ kind = "link" => q \notin links[p]
    /\ kind = "monitor" => q \notin mons[p]
    /\ budget' = budget - 1
    /\ lane' = [lane EXCEPT ![<<p, q>>] =
                   Append(@, <<kind, p, q,
                               IF kind = "msg" THEN nsent[<<p, q>>] + 1
                               ELSE 0>>)]
    /\ nsent' = IF kind = "msg" THEN [nsent EXCEPT ![<<p, q>>] = @ + 1]
                ELSE nsent
    /\ links' = IF kind = "link" THEN [links EXCEPT ![p] = @ \cup {q}]
                ELSE links
    /\ mons' = IF kind = "monitor" THEN [mons EXCEPT ![p] = @ \cup {q}]
               ELSE mons
    /\ UNCHANGED <<alive, up, view, watched, got>>

Die(q) ==
    /\ budget > 0 /\ alive[q]
    /\ budget' = budget - 1
    /\ alive' = [alive EXCEPT ![q] = FALSE]
    /\ lane' = DeathLanes(q, lane)
    /\ links' = [links EXCEPT ![q] = {}]
    /\ watched' = [watched EXCEPT ![q] = {}]
    /\ UNCHANGED <<up, view, mons, nsent, got>>

\* A domain ends; the kernel's exit record makes its lanes' contents final,
\* and the system domain tells each peer connection_down.
DomainEnd(d) ==
    /\ budget > 0 /\ up[d]
    /\ budget' = budget - 1
    /\ up' = [up EXCEPT ![d] = FALSE]
    /\ alive' = [alive EXCEPT ![d] = FALSE]
    /\ view' = [x \in Pairs |->
                   IF x[2] = d /\ view[x] = "up" THEN "draining" ELSE view[x]]
    /\ UNCHANGED <<lane, links, mons, watched, nsent, got>>

\* d's runtime ends its connection with e (a malformed frame, or its own
\* policy): it stops reading e's lane and fires its relations with e's
\* process with noconnection; e is told connection_down and drains.
EndConn(d, e) ==
    /\ up[d] /\ d # e /\ view[<<d, e>>] = "up"
    /\ view' = [view EXCEPT ![<<d, e>>] = "down",
                            ![<<e, d>>] = IF @ = "up" THEN "draining" ELSE @]
    /\ lane' = [lane EXCEPT ![<<e, d>>] = <<>>]
    /\ got' = IF alive[d] THEN [got EXCEPT ![d] = @ \o Fired(d, e)] ELSE got
    /\ links' = [links EXCEPT ![d] = @ \ {e}]
    /\ mons' = [mons EXCEPT ![d] = @ \ {e}]
    /\ watched' = [watched EXCEPT ![d] = @ \ {e}]
    /\ UNCHANGED <<alive, up, nsent>>

\* A runtime forges an answer about another domain's process q.
Forge(d, q, p) ==
    /\ budget > 0 /\ up[d] /\ q # d /\ p # d /\ q # p /\ view[<<d, p>>] = "up"
    /\ budget' = budget - 1
    /\ lane' = [lane EXCEPT ![<<d, p>>] =
                   Append(@, <<"down", q, p, nsent[<<q, p>>]>>)]
    /\ UNCHANGED <<alive, up, view, links, mons, watched, nsent, got>>

-----------------------------------------------------------------------------
(* Owed steps: what the runtimes must do. *)

\* d's runtime takes the next frame f from e's lane, f = <<kind, from, to,
\* stamp>>, and acts for its process to:
\*   * the sender rule: from must be e's own process, or the frame is
\*     malformed; d ends the connection, or, already draining, stops the
\*     drain there;
\*   * "msg": delivered if to lives, dropped otherwise;
\*   * "link", "monitor": recorded if to lives and e holds the right on
\*     it (answerable), otherwise answered noproc behind everything d has
\*     queued for e, unless d is draining e, which then drops it.  A link
\*     needs no right when to already holds a link with from (linkable):
\*     the frame creates nothing, and a noproc would end from's half of a
\*     link whose other half exists;
\*   * "kill" (exit/2): to dies if e holds the right, and its runtime
\*     writes its death's exits and DOWNs behind what it queued;
\*   * "exit", "down": an answer, delivered to to only for a link or
\*     monitor it holds with from, which it then drops.
Receive(d, e) ==
    /\ up[d] /\ view[<<d, e>>] \in {"up", "draining"} /\ lane[<<e, d>>] # <<>>
    /\ LET f == Head(lane[<<e, d>>])
           kind == f[1]
           from == f[2]
           to == f[3]
           stamp == f[4]
           rest == [lane EXCEPT ![<<e, d>>] = Tail(@)]
           answerable == alive[to] /\ <<e, to>> \in Exported
           linkable == \/ answerable
                       \/ alive[to] /\ from \in links[to] /\ Fault # "noproc_on_link"
           noproc(k) == IF view[<<d, e>>] # "up" \/ Fault = "no_noproc"
                        THEN rest
                        ELSE IF Fault = "answer_first"
                        THEN [rest EXCEPT ![<<d, e>>] =
                                 <<<<k, to, from, nsent[<<d, e>>]>>>> \o @]
                        ELSE [rest EXCEPT ![<<d, e>>] =
                                 Append(@, <<k, to, from, nsent[<<d, e>>]>>)]
       IN
       IF from # e /\ Fault # "any_lane"
       THEN IF view[<<d, e>>] = "up" THEN EndConn(d, e) /\ UNCHANGED budget
            \* Already draining: the drain stops at the malformed frame.
            ELSE /\ lane' = [lane EXCEPT ![<<e, d>>] = <<>>]
                 /\ UNCHANGED <<alive, up, view, links, mons, watched, nsent, got,
                                budget>>
       ELSE /\ CASE kind = "msg" ->
                    /\ got' = IF alive[to]
                              THEN [got EXCEPT ![to] = Append(@, <<"msg", from, stamp>>)]
                              ELSE got
                    /\ lane' = rest
                    /\ UNCHANGED <<alive, links, watched>>
                 [] kind = "link" ->
                    /\ links' = IF linkable THEN [links EXCEPT ![to] = @ \cup {from}]
                                ELSE links
                    /\ lane' = IF linkable THEN rest ELSE noproc("exit")
                    /\ UNCHANGED <<alive, watched, got>>
                 [] kind = "monitor" ->
                    /\ watched' = IF answerable THEN [watched EXCEPT ![to] = @ \cup {from}]
                                  ELSE watched
                    /\ lane' = IF answerable THEN rest ELSE noproc("down")
                    /\ UNCHANGED <<alive, links, got>>
                 [] kind = "kill" ->
                    /\ alive' = IF answerable THEN [alive EXCEPT ![to] = FALSE] ELSE alive
                    /\ lane' = IF answerable THEN DeathLanes(to, rest) ELSE rest
                    /\ links' = IF answerable THEN [links EXCEPT ![to] = {}] ELSE links
                    /\ watched' = IF answerable THEN [watched EXCEPT ![to] = {}] ELSE watched
                    /\ UNCHANGED got
                 [] kind = "exit" ->
                    /\ got' = IF alive[to] /\ from \in links[to]
                              THEN [got EXCEPT ![to] = Append(@, <<"answer", from, stamp>>)]
                              ELSE got
                    /\ links' = [links EXCEPT ![to] = @ \ {from}]
                    /\ lane' = rest
                    /\ UNCHANGED <<alive, watched>>
                 [] kind = "down" ->
                    /\ got' = IF alive[to] /\ from \in mons[to]
                              THEN [got EXCEPT ![to] = Append(@, <<"answer", from, stamp>>)]
                              ELSE got
                    /\ lane' = rest
                    /\ UNCHANGED <<alive, links, watched>>
            /\ mons' = IF kind = "down" THEN [mons EXCEPT ![to] = @ \ {from}] ELSE mons
            /\ UNCHANGED <<up, view, nsent, budget>>

\* Told connection_down: once e's lane is drained to its final position,
\* fire every relation with e's process, and drop what d wrote for e.  With
\* the fault, d fires first and goes on draining; a second firing finds no
\* relation left and appends nothing.
FinishDrain(d, e) ==
    /\ up[d] /\ view[<<d, e>>] = "draining"
    /\ Fault = "fire_before_drain" \/ lane[<<e, d>>] = <<>>
    /\ view' = [view EXCEPT ![<<d, e>>] =
                   IF lane[<<e, d>>] = <<>> THEN "down" ELSE "draining"]
    /\ lane' = [lane EXCEPT ![<<d, e>>] = <<>>]
    /\ got' = IF alive[d] THEN [got EXCEPT ![d] = @ \o Fired(d, e)] ELSE got
    /\ links' = [links EXCEPT ![d] = @ \ {e}]
    /\ mons' = [mons EXCEPT ![d] = @ \ {e}]
    /\ watched' = [watched EXCEPT ![d] = @ \ {e}]
    /\ UNCHANGED <<alive, up, nsent, budget>>

Owed == \E x \in Pairs : Receive(x[1], x[2]) \/ FinishDrain(x[1], x[2])

Choice ==
    \/ \E x \in Pairs, kind \in {"msg", "link", "monitor", "kill"} :
           Initiate(x[1], x[2], kind)
    \/ \E d \in Doms : Die(d) \/ DomainEnd(d)
    \/ \E d, q, p \in Doms : Forge(d, q, p)
    \/ \E x \in Pairs : budget > 0 /\ EndConn(x[1], x[2]) /\ budget' = budget - 1

\* Nothing owed is left: every running domain has read each lane into it
\* and finished every drain.
Quiet == \A x \in Pairs : up[x[2]] => /\ lane[x] = <<>>
                                      /\ view[<<x[2], x[1]>>] # "draining"

\* p holds a link or monitor on q.
Held(p, q) == q \in links[p] \cup mons[p]

\* No answer is owed: every relation a live process holds is with a live
\* process over a connection that is up.  Quiet says the runtimes have no
\* step left; Settled says they did what was owed, so a runtime that stops
\* short leaves a terminal state the deadlock check reports.
Settled ==
    \A p, q \in Doms : p # q /\ alive[p] /\ Held(p, q) =>
        alive[q] /\ view[<<p, q>>] = "up"

\* The one acceptable terminal state: no initiating step remains, nothing
\* owed is left and every relation is settled.
Finished ==
    /\ budget = 0 \/ \A d \in Doms : ~up[d]
    /\ Quiet
    /\ Settled
    /\ UNCHANGED vars

Next == Owed \/ Choice \/ Finished

Fairness == \A x \in Pairs : WF_vars(Receive(x[1], x[2]))
                             /\ WF_vars(FinishDrain(x[1], x[2]))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties. *)

TypeOK ==
    /\ alive \in [Doms -> BOOLEAN] /\ up \in [Doms -> BOOLEAN]
    /\ view \in [Pairs -> {"up", "draining", "down"}]
    /\ budget \in 0..Budget

\* D9: a process's messages to one receiver arrive in the order sent, and
\* every answer about a process arrives after everything that process sent
\* the holder before the answer was made.
AnswersAfterSends ==
    \A p \in Doms : \A i, j \in 1..Len(got[p]) :
        LET a == got[p][i]
            b == got[p][j]
        IN i < j /\ b[1] = "msg" /\ a[2] = b[2] => a[3] < b[3]

\* No relation's terminal signal is lost: a live holder of a link or
\* monitor of a dead process is eventually given one more answer about
\* it, not merely relieved of the relation.  Each answer needs a
\* relation, and each relation an initiating step, so a holder gets at
\* most Budget answers about one process.
Answers(p, q) == Len(SelectSeq(got[p], LAMBDA g : g[1] = "answer" /\ g[2] = q))
AnswersArrive ==
    \A p, q \in Doms, n \in 0..Budget : p # q =>
        ((alive[p] /\ Held(p, q) /\ ~alive[q] /\ Answers(p, q) = n)
         ~> (~alive[p] \/ Answers(p, q) > n))

\* Reachability witness: a live holder of a relation with a process of an
\* ended domain drains a lane that still holds a message from it, so the
\* drain comes before the firing in some behaviour.
DrainNeverMatters ==
    ~\E p, q \in Doms :
        /\ p # q /\ up[p] /\ alive[p] /\ ~up[q] /\ Held(p, q)
        /\ view[<<p, q>>] = "draining"
        /\ \E i \in 1..Len(lane[<<q, p>>]) : lane[<<q, p>>][i][1] = "msg"
=============================================================================
