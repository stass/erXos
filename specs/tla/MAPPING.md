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

Code marked *(not implemented)* does not exist: the lane's producer
side in `liberx/erx_lane.c`, the lane port driver and its drain, the
connection agent and `erx_dist`, and the domain service's effects for
connections, whose pure core is `erx_domain_links`.
Each arrives with the host test or assertion named here, or its commit
explains why the model's abstraction holds unchanged.

| Model/property | Scope | Implementation and evidence |
| --- | --- | --- |
| Lane / ReadBehindWrite, NoOverwrite | 8-unit lane, records of 1, 10, 2 units | consumer: `lane_check_wpos` in `liberx/erx_lane.c` refuses a `wpos` behind `rpos` or more than the size ahead; producer: `erx_lane_put` computes room from its acquire load of `rpos` *(not implemented)*; `test/host/lane_test.rb` position checks |
| Lane / WholeRecords | as above | `erx_lane_take` copies a record as it is published, `lane_release` stores `rpos` only behind copied bytes; host test of a record cut at every 16-byte boundary and across the area's end |
| Lane / NoLostWait, Progress | as above, weak fairness of each party | consumer waiter: `erx_lane_take_armed` stores `wake`, fences, loads `wpos`; consumer mover: `lane_release` stores `rpos`, fences, loads `need`, rings by `lane_crossed`; producer mover and waiter: `erx_lane_put`, `erx_lane_room_wanted`, `erx_lane_sleeping` *(not implemented)*; herd7 litmus tests with and without each fence *(not implemented)* |
| Lane / RingOnlyOnCrossing | as above | movers ring through `lane_crossed` only *(producer not implemented)*; host test counting rings against stored waits *(not implemented)* |
| Lane / ProducerNeverRung | witness | producer park and wake path exercised by the lane host test *(not implemented)* |
| Connection / EndedPeerDrained (D17) | 2 frames on the peer's lane to A, two incarnations | drain to the `wpos` read at `connection_down`, then fire *(not implemented)*; QEMU test that kills a domain mid-burst |
| Connection / OrderedThenDown (D9) | as above | one lane read in order through the funnel; the port stops reading at down *(not implemented)* |
| Connection / NoUseAfterDelete (D16) | as above | the domain service's core, `erx_domain_links`, returns `{disconnect, Handle}` only once both sides have let go, by answering `connection_unmapped` or `connection_lost`, by ending, or by never being told (`retire/2`); `test/erlang/erx_domain_links_tests.erl` explores every interleaving and checks `no_use_after_delete`, also with either side hostile, and `survivor_that_never_answers_keeps_the_connection_test`; the agent unmaps before it answers *(not implemented)* |
| Connection / OneControlRecord | as above | `erx_domain_links` keeps a queue per party and peer name and sends only from its head, which has at most one record outstanding (`advance/3`, `next_record/3`), and counts a connection against a party's `connections` until its side is done (`held/2`); exploration property `one_control_record` for both parties, also with either side hostile; the reserve of the lane from the system domain *(not implemented)* |
| Connection / OneEntry | as above | `erx_domain_links` queues a later domain's `connection_up` behind the earlier connection's side, which leaves the queue only once the party answered its `connection_down` or ended the connection itself (`set_side/4`); exploration property `one_entry`; the agent answers only after unmapping *(not implemented)* |
| Connection / TypeOK | as above | `erx_domain_links` applies an answer only in the side state that expects it and drops and counts every other (`answered/2`), explored with either side also sending any well-formed answer once, and with malformed answers in a scenario test; the agent answers only records it was sent *(not implemented)* |
| Connection / Settles | weak fairness of the service and of A only | no step of A or the service waits on the peer: the drain's target is read once *(not implemented)*, the answer does not wait for the peer's unmap *(not implemented)* |
| Connection / LaterNeverUp | witness | exploration witness `later_up_at_a`; test that a later domain of the same name reaches the peer as `nodedown` then `nodeup` *(not implemented)* |
| Links / AnswersAfterSends (D9) | 3 domains, 3 initiating steps | the sender rule admits an answer only from its process's domain: `erx_funnel_control` in `liberx/erx_funnel.c` decodes the sending pid, and the lane driver compares its node name and domain id with the lane's *(not implemented)*; a runtime's exit path writes exits and `DOWN`s behind the process's frames; `noproc` written on the reverse lane behind queued frames; three-domain property test |
| Links / AnswersArrive, Settled (terminal step) | as above, weak fairness of receives and drains; 3 steps over the one-way pair | `noproc` for a link or monitor of a dead or unexported process, and for a `LINK` only when the target holds no link with the sender, counting one awaiting an unlink acknowledgement *(not implemented)*; fire on connection down after the drain *(not implemented)* |
| Links / DrainNeverMatters | witness | QEMU test that kills a domain mid-burst with monitors held *(not implemented)* |

### Connection.tla's actions in the domain service's core

The domain service's side of `Connection.tla` is
`erlang/apps/erx_domain/src/erx_domain_links.erl`, a pure state machine
whose functions return the actions the service performs.

| Action | `erx_domain_links` |
| --- | --- |
| Introduce(c) | `connect/4`: records the connection and queues `connection_up` for each party |
| Close(c), the peer's end | `ended/3`, once the fault gate reports the end |
| Close(c), `connection_lost` from either party | `answer/3` with `{connection_lost, Peer, Reason}` |
| Policy(c) | `close/3` |
| Send | `advance/3` on A's queue for the peer name: the head's next record, by `next_record/3` |
| TellPeer(c) | `advance/3` on the peer's queue: the same rule, applied to both parties |
| Delete(c) | `retire/2`, which returns `{disconnect, Handle}` |
| ReadUp, FinishDown, ReadDownLost, ALose | `answer/3` from A: `connection_mapped`, `connection_unmapped`, `connection_lost` |
| PMap, PUnmap, PLose | `answer/3` from the peer |
| PStart | `add_party/3` and `ready/2` for the later incarnation |

The core and its explorer depart from the model in these ways, explored
by `erx_domain_links_tests` except where said:

* A record waits until its party is ready (`ready/2`); in the model every
  party is ready from the start.
* The model's `owed` counts A's records only; the core keeps one
  outstanding record per party and peer name, for A and the peer alike.
* A connection that closes before its `connection_up` went to a party is
  never sent to it: that side is untold and counts as let go. The model
  still sends the queued `connection_up` and then the `connection_down`.
* A party that ends a connection itself while its `connection_down` is
  outstanding still answers that record with `connection_unmapped`, peer
  and A alike; the model's peer leaves it unanswered. Only the record
  waits for it: the objects are deleted once both sides have let go.
* A connection whose sides are all done is forgotten, which every run's
  end checks, so the same pair may be introduced again; the model
  introduces each connection once, and the explorer does not reintroduce
  a pair.
* The explorer introduces a peer that has ended before the service has
  learnt of its end, which the model's `Introduce` does not.
