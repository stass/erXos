# Property mappings

| Model/property | Scope | Implementation and evidence |
| --- | --- | --- |
| RunnerSmoke / Bounded | counter 0..2 in good mode; 0..3 in broken mode | `TlcOutput.classify` distinguishes completed search from the named safety failure; host fixtures and real pinned-TLC runs |
| RunnerSmoke / initial Bounded violation | initial counter 3 | initial-state diagnostic preserves the exact invariant and tool failure status |
| RunnerSmoke / NotReached | counter reaches 2 | expected failure witnesses the path and checks exact property identity |

These are harness fixtures with no erXos protocol implementation mapping.
The protocol model owners add state/action/assumption mappings alongside
their real mechanisms.

## Connection models

Implementation names marked *(pending)* belong to packages not yet landed:
the lane writer (RT4), the lane port driver and drain (RT6a), the
connection agent and `erx_dist` (RT6b), the domain service's connections
(SV2). Each lands with the host test or assertion named here, or explains
in its commit why the model's abstraction holds unchanged.

| Model/property | Scope | Implementation and evidence |
| --- | --- | --- |
| Lane / ReadBehindWrite, NoOverwrite | 8-unit lane, records of 1, 10, 2 units | consumer: `lane_check_wpos` in `liberx/erx_lane.c` refuses a `wpos` behind `rpos` or more than the size ahead; producer: `erx_lane_put` computes room from its acquire load of `rpos` *(pending, RT4)*; `test/host/lane_test.rb` position checks |
| Lane / WholeRecords | as above | `erx_lane_take` copies a record as it is published, `lane_release` stores `rpos` only behind copied bytes; host test of a record cut at every 16-byte boundary and across the area's end |
| Lane / NoLostWait, Progress | as above, weak fairness of each party | consumer waiter: `erx_lane_take_armed` stores `wake`, fences, loads `wpos`; consumer mover: `lane_release` stores `rpos`, fences, loads `need`, rings by `lane_crossed`; producer mover and waiter: `erx_lane_put`, `erx_lane_room_wanted`, `erx_lane_sleeping` *(pending, RT4)*; herd7 litmus tests with and without each fence *(pending, RT4)* |
| Lane / RingOnlyOnCrossing | as above | movers ring through `lane_crossed` only *(producer pending, RT4)*; host test counting rings against stored waits *(pending, RT4)* |
| Lane / ProducerNeverRung | witness | producer park and wake path exercised by the lane host test *(pending, RT4)* |
| Connection / EndedPeerDrained (D17) | 2 frames each way, two incarnations | drain to the `wpos` read at `connection_down`, then fire *(pending, RT6a)*; QEMU test that kills a domain mid-burst |
| Connection / OrderedThenDown (D9) | as above | one lane read in order through the funnel; the port stops reading at down *(pending, RT6a)* |
| Connection / NoUseAfterDelete (D16) | as above | domain service deletes a connection's objects only after each party's `connection_unmapped` or `connection_lost`, or its end *(pending, SV2)*; test that a survivor that never answers keeps the objects |
| Connection / OneControlRecord | as above | the service's per-name queue of control records, one outstanding *(pending, SV2)*; the reserve of the lane from the system domain *(pending, RT6b)* |
| Connection / OneEntry | as above | the service's queue sends a later domain's `connection_up` only after the earlier connection's `connection_down` went out and was answered (design-domains.md, Connections) *(pending, SV2)*; the agent answers only after unmapping *(pending, RT6b)* |
| Connection / TypeOK | as above | the agent answers only records it was sent *(pending, RT6b)* |
| Connection / Settles | weak fairness of the service and of A only | no step of A or the service waits on the peer: the drain's target is read once *(pending, RT6a)*, the answer does not wait for the peer's unmap *(pending, RT6b)* |
| Connection / LaterNeverUp | witness | test that a later domain of the same name reaches the peer as `nodedown` then `nodeup` |
| Links / AnswersAfterSends (D9) | 3 domains, 3 initiating steps | the sender rule admits an answer only from its process's domain: `erx_funnel_control` in `liberx/erx_funnel.c` decodes the sending pid, and the lane driver compares its node name and domain id with the lane's *(pending, RT6a)*; a runtime's exit path writes exits and `DOWN`s behind the process's frames; `noproc` written on the reverse lane behind queued frames; three-domain property test |
| Links / AnswersArrive | as above, weak fairness of receives and drains; 3 steps over the one-way pair | `noproc` for a link or monitor of a dead or unexported process, and for a `LINK` only when the target holds no link with the sender, counting one awaiting an unlink acknowledgement *(pending, RT6b)*; fire on connection down after the drain *(pending, RT6a)* |
| Links / DrainNeverMatters | witness | QEMU test that kills a domain mid-burst with monitors held *(pending, RT6a)* |
