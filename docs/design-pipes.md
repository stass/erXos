# Pipes

A **pipe** carries bytes one way, from its write ends to its read ends, and
erXos builds it in user space, in `liberx` and in each session, from kernel
objects that exist for other reasons: memory objects and IRQ objects used
as doorbells. Each write end writes into a **lane** of its own, a
single-producer, single-consumer **ring** and a **reader page**, so writers
never share memory; the read ends merge the lanes in write order; and
every end is made and installed by the session's pipe server, for exactly
one holder, so the session knows every holder of every pipe and end of
stream and broken pipe follow from its records, whatever the holders do or
however they end. The key idea is that every pipe has a **home**, the
session its programs belong to: its pipe server creates the pipe's
objects, installs each end into the one program or process that holds it,
and tells each holder, through that holder's channel, which other ends
exist, while bytes travel only through the lanes, never through the
session or the kernel. Programs' standard streams and POSIX pipes
([design-programs.md](design-programs.md)) and Erlang commands that meet
programs in a pipeline
([design-runtime.md](design-runtime.md#the-console-and-standard-io),
[design-shell.md](design-shell.md#pipelines)) all use these pipes. The
lane is also the shape of every other byte stream in the system: a
program's channel to its session
([design-programs.md](design-programs.md#the-channel)) and each direction
of a connection between two domains are lanes of the same layout, which
[design-domains.md](design-domains.md#connections) defines with its wake
handshake, and a pipe adds to it only what merging several writers
needs. The kernel's objects are in [design-kernel.md](design-kernel.md); a
program's creation, its channel and its table in
[design-programs.md](design-programs.md#a-program-is-a-port).

Decisions every reader of this document needs:

* **Pipes are not kernel objects**, by the user's decision. The kernel
  provides memory objects and IRQ objects used as doorbells; `liberx` and
  the session do the rest, and the data path makes no kernel call while
  the other side is awake.
* **One lane per write end.** A writer writes only its own ring, which its
  readers map read-only, so a hostile writer can corrupt only its own
  records, a hostile reader can corrupt no writer's, and a write of at most
  `PIPE_BUF` bytes is one record, read whole.
* **The session is every pipe's home.** Its pipe server creates every
  lane, lock page and doorbell, installs each end into its one holder, and
  tells each holder of every other end; a program never installs an end
  and never hands one to another program: it receives ends the session
  made for it.
* **End of stream follows from the session's records.** Only the session
  installs ends, so it knows every holder; a holder's close and a holder's
  death both reach it, by a notice on the holder's channel or by the end
  record of the holder's space, and it tells the other holders. No field
  of shared memory decides end of stream or broken pipe.
* **Several readers share one stream.** Read ends share the lanes and a
  reader lock, as POSIX processes share a pipe. A pipe has any number of
  write ends, bounded only by the session's quotas, so a pipe with many
  writers blocks a writer and never a spawn; it has at most 64 read ends.

## Context

A UNIX pipe is a kernel buffer: the kernel serialises writers and readers
and knows when the last end goes. erXos's kernel keeps no pipe object, by
the user's decision, so the buffer, its arbitration and its end-of-stream
rule live in user space, built from the kernel's general objects
([design-kernel.md](design-kernel.md)):

* **Memory objects** hold the lanes and each pipe's lock page. Copies of a
  capability are independent slots, a mapping keeps its object until it is
  unmapped, and only a holder of `DESTROY` can delete an object, which
  makes every mapping of it fault
  ([design-kernel.md](design-kernel.md#closing-and-deleting)). The pipe
  server creates every pipe's memory, installs copies without `DESTROY`
  into the holders, and never deletes it, so nothing can make a party that
  maps a pipe's page fault: the kernel's rule for servers. Every pipe
  object, its lanes, lock page and doorbells, is charged to the session's
  own budget and never to a program's: destroying a budget deletes every
  object charged to it at once
  ([design-kernel.md](design-kernel.md#budgets)), so an object charged to
  the program that ends would vanish under the other holders that map
  it. A pipe's memory returns to the session's budget when its last
  holder has closed and unmapped it.
* **IRQ objects triggered by software** are the doorbells. The pipe server
  creates each end's doorbell and binds it to the holder's scheduling
  group with the end as its label, since it holds the right to bind on
  every group it created
  ([design-kernel.md](design-kernel.md#irq-objects)), and installs
  `TRIGGER` alone into the end's peers. That is the session's choice,
  since an install into a space it created is not bound by the pass set.
  So any number of peers ring the doorbell, and nothing else about it is
  theirs to change. A trigger that comes before its holder waits is kept,
  and triggers that come meanwhile count once.
* **The time page** gives a monotonic clock that user mode reads without a
  kernel call; records carry its value to order writers.
* **umtx words** are `liberx`'s one way to wait: a worker sleeps on its
  wake word, and the program's event executor wakes it when a doorbell it
  waits for comes up in the group's ready list
  ([design-programs.md](design-programs.md#the-event-executor)). Pipes add
  no wait of their own.
* **The channel** carries, between a program and its handler, every
  request about a pipe and every report about its other ends, in order and
  without loss, since the session is its one writer and the program its one
  reader ([design-programs.md](design-programs.md#the-channel)); the
  session's own processes get the same reports as messages.

The design follows the shape of the seL4 Device Driver Framework's queues,
single-producer, single-consumer rings in shared memory with a signal for
each side ([research](research-kernel-bases.md#sddf)), with a stricter
layout: the producer alone writes the ring and the consumer alone writes
the reader page, so each maps the other's page read-only. Fiasco has no
kernel pipe either; how this design relates to Fiasco's model is recorded
with the kernel's other departures
([design-kernel.md](design-kernel.md#l4-lineage)).

Programs ask their session for everything a pipe's structure needs: a
program's handler, a process of the session's command server, already
starts its children, installs what they hold and reports their ends
([design-programs.md](design-programs.md#starting-a-program)). Pipes add a
**pipe server**, `erx_pipe_srv`, to each session, and nothing to the data
path.

## Requirements

* **PR1. POSIX behaviour.** Bytes of one writer arrive in the order
  written; a write of at most `PIPE_BUF` (4,096) bytes is never interleaved
  with another writer's bytes; a read of an empty pipe returns 0 once no
  write end remains, fails with `EAGAIN` under `O_NONBLOCK` while one does,
  and otherwise waits; a write with `O_NONBLOCK` of at most `PIPE_BUF`
  bytes goes in whole or fails with `EAGAIN`, and a larger one writes what
  fits or fails with `EAGAIN` when nothing does; a write once no read end
  remains fails with `EPIPE` and sends the thread `SIGPIPE`; `poll` and
  `select` report each end's readiness (POSIX Issue 8: `pipe`, `read`,
  `write`, `poll`).
* **PR2. End of stream and broken pipe by construction.** They follow from
  who holds the ends, whatever the holders do and however they end: a
  close, a fault, a kill, or the end of the session's tree.
* **PR3. Isolation.** Writers never share memory; a hostile writer can
  corrupt only its own records and cannot starve the others; a hostile
  reader can harm only the stream it shares with its co-readers, as a UNIX
  reader that stops reading or reads everything can, and no writer's
  records; nothing a holder writes into shared memory makes another party
  crash, loop, or touch memory out of bounds.
* **PR4. Sharing.** Many writers and several readers per pipe, created and
  ended as programs start, inherit, pass on and end, as POSIX processes
  share pipes; a program's own `dup` shares one end. A spawn or a fork that
  inherits a write end never fails for the number of writers the pipe has:
  `make 2>&1 | less` with the pager paused spawns its 64th child, whose
  writes wait for room as any writer's do.
* **PR5. Bounded state.** Each pipe's memory and each end's objects are
  bounded, charged to the session and limited by its quota; every parse of
  shared memory and every message is bounded.
* **PR6. A cheap data path.** No kernel call per transfer while the other
  side is awake; one copy on each side; at most one doorbell per batch.

Non-goals:

* Named pipes (`mkfifo`): no file server serves them.
* Linux's `splice`, `tee`, `vmsplice`, `F_SETPIPE_SZ` and `O_DIRECT` packet
  mode, which fail with `EINVAL`.
* Pipes between sessions: a pipe's ends all belong to one session's tree,
  where its home is. Bytes between two sessions' programs, and between a
  program and an Erlang command that runs in a domain of its own, are
  relayed by the session over its connection, as
  [design-programs.md](design-programs.md#what-a-program-can-start)
  describes for command domains; that path is rare and may be slow.

## Overview

```text
                          session domain
            +-----------------------------------------------+
            | erx_pipe_srv: makes every lane, the lock page  |
            | and every doorbell; installs each end into its |
            | one holder; knows every holder                 |
            +-----------------------------------------------+
                | reports and capabilities, through each
                v holder's channel and capability table
   +----------------------+                      +------------------------+
   | writer A             |  records in lane A   | reader R               |
   |  lane A: ring (rw),  |--------------------->|  lanes A and B: ring   |
   |  reader page (ro)    |                      |  (ro), reader page (rw)|
   +----------------------+                      |  the lock page (rw)    |
   +----------------------+  records in lane B   |                        |
   | writer B             |--------------------->|                        |
   |  lane B              |                      +------------------------+
   +----------------------+   a writer rings R's doorbell when R sleeps;
                              R rings a writer's doorbell when it waits for room
```

A pipe's life, end to end. A program calls `pipe`; its handler asks the
pipe server, which creates the pipe's lock page, one lane, and a doorbell
for each of the two ends, bound to the program's group with the end as
its label; keeps its own capabilities to them; and has the program's
handler install into the program the copies each end needs. The program
spawns a child that inherits the write end: the pipe server makes a write
end for the child, with a lane and a doorbell of its own, raises the
lock page's count of write ends, installs the lane and the doorbell's
trigger right into the reader and tells it `{pipe_writer, ...}`, and
hands the child's handler the child's copies, which are installed before
the child's first thread runs. A writer copies
each write into its ring as a record stamped with the monotonic clock,
publishes it by advancing its write position, and rings each sleeping
reader's doorbell. A reader takes, among the first records of its lanes,
the one written first, copies it out, advances that lane's read position,
and rings the writer's doorbell if the writer waits for room. When a writer
closes its end, its `liberx` tells the handler, and when a writer ends, the
handler sees the end record of its space; either way the pipe server
learns that the end is gone, closes its own capabilities to the lane, and
tells every reader `{pipe_writer_gone, ...}`; a reader that has drained
every lane whose writer is gone and holds no open one returns 0. When the
last read end goes, the pipe server tells every writer, whose next write
fails with `EPIPE`. When no end of either kind remains, the pipe server
forgets the pipe, and the memory returns to the session's budget as the
last mappings go.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PI1.** Every pipe end has exactly one holder, which the session knows | only the session's pipe server makes an end, and it installs the end's capabilities into one holder's table through that holder's handler, or hands them to a session process, recording the holder as it does; a program's table takes capabilities only from its session ([design-programs.md](design-programs.md#invariants), P1), and every copy the session installs lacks `DUP` and `GIVE`, so a holder cannot copy an end or hand one on at a rendezvous; a program's `dup` shares one end object in its own table, and an end another program receives is one the pipe server made for it | a copy of a lane or a doorbell with `DUP` or `GIVE`; an end installed by anyone but the pipe server; a holder recorded wrongly | the pipe server's model, in which every end has one recorded holder after every event; a domain test that tries to copy an end's capabilities with `erx_cap_dup` and to pass them at a rendezvous, and gets `ERX_ERIGHTS` each time |
| **PI2.** A reader sees the end of the stream once, and only once, no write end remains and every byte written has been read | a write end's close reaches the pipe server as a notice from the holder's `liberx` or as the end record of the holder's space, both of which its handler sees, and the pipe server tells every read end's holder in order on its channel; a write end is made only for a child, a deposit or a redeemer of a write end its requester holds, so once no write end remains none can appear; the pipe server lets go of a lane only after every read end has reported it drained, and never deletes one, so a gone writer's bytes stay readable; a reader returns 0 only when it holds no lane whose writer is open and finds every lane whose writer is gone drained, and a read end that has found such a lane drained counts it drained from then on, so records that a writer which kept its ring publishes after it said it closed never follow the end of the stream | a write end made from a closed end; a lane let go before every reader drained it; a reader that reads a lane it has found gone and drained; a read that returns 0 while a lane holds a record or while a writer is open | the pipe core's exploration; domain tests: `echo hi \| cat`, a writer that faults mid-stream, a writer that closes and goes on publishing, two writers in two programs, and a write end inherited by a program as it ends |
| **PI3.** A writer gets `EPIPE` once, and only once, no read end remains | a read end's close or its holder's death reaches the pipe server, which tells every writer `{pipe_reader_gone, ...}`, and each writer counts its read ends from those reports alone; read ends are made only for a child, a deposit or a redeemer of a read end its requester holds, so none appears once none remains; a writer fails with `EPIPE` only on a count of zero or when the pipe is lost, both from its handler's reports, which no reader can write | a read end made from nothing; a count lowered while its read end remains; `EPIPE` taken from a field a reader can write | the pipe core's exploration; domain tests: a reader that faults while its writer waits for room, `yes \| head -1`, and a co-reader that rewrites a lane's read position, which stops its writer but never sends it `SIGPIPE` |
| **PI4.** Writers never share memory, no reader can write a writer's records, and nothing in shared memory makes a party crash, loop or touch memory out of bounds | each write end writes only its own ring, which every read end maps read-only; a write end maps its lane's reader page read-only and nothing else of the pipe; every party copies each field it reads from a page others write once into private memory and validates the copy with checked arithmetic before use; every loop is bounded by the pipe's limits and the party's own records, never by a value read from shared memory | a reader with a writable mapping of a ring; a field used twice from shared memory; a check after use; a loop bounded by a value read from a page | the ring checks' fuzz targets; a hostile-writer domain test that rewrites its header and records at random while a reader reads; a reader that tries to write a ring, which faults on its read-only mapping |
| **PI5.** A write of at most `PIPE_BUF` bytes reaches the readers contiguously | it is one record, published by one store of the write position; a read that takes part of a record leaves the rest as the lock page's current record, and every reader finishes the current record before it takes another | a record split before its publication; a reader that switches lanes inside a record | the exploration with 4,096-byte writes; a domain test with 100 writers writing 4,096-byte lines, whose lines all arrive whole |
| **PI6.** One writer's bytes arrive in the order written; of two writes by different writers, one that happened before the other is read first; and no writer delays another's record without bound | each writer has its own lane, read in order; the pipe server stores a write end's number in the lock page's `wends` before it installs the end anywhere, and a reader that finds a record copies `wends` and, when it names a write end whose report the reader has not applied, waits for that report, which is already on its own channel, before it picks, so it picks only with every lane that existed before the record it found; the reader merges the lanes by an order key that puts every record after each record that happened before it; and a batch never grows, so another writer's later bytes delay a record by at most two lanes' capacity for each read end ([Reading and merging](#reading-and-merging)) | a reader that misses a lane which became readable before the record it picked; a write end installed before its number is in `wends`; a reader that picks while `wends` names a write end it has not applied; a mark taken after a look that did not include its record; a batch that grows after it opens | the exploration, which checks the bound after every event; domain tests: `{date; uname} \| cat`, whose lines arrive in that order every time; a child writer that writes a line and exits, after which its parent writes one, while the reader's event executor is held back from applying the child's lane, whose lines arrive in that order, with a seeded reader that ignores the lock page's `wends`, which the test catches; and a writer that stamps every record 0 and never lets its ring empty while another writer's records arrive within the bound |
| **PI7.** No wakeup is lost | a waiter publishes the position or bit it waits for, fences and checks again before it sleeps; a party that publishes data, room or the lock fences and then rings each waiter whose published position its store crossed or whose bit it finds set ([design-domains.md](design-domains.md#connections)); every peer holds the trigger right on an end's doorbell from before the end's holder can wait on it, since the session installs the end and its peers' trigger rights before the holder runs or before it answers the request that made the end. A peer learns the new end's doorbell only from its handler's report, so a waiter may publish before the peer can ring it; the peer therefore rings the new end's doorbell once as it applies the report, and the waiter wakes and checks again. The session's reports of a gone end reach the holder through its channel, whose doorbell wakes the event executor, which wakes the end's waiters ([Waiting and doorbells](#waiting-and-doorbells)) | a check before what the waiter published is visible; a doorbell that forgets a ring; an end whose holder can run before its peers hold its doorbell; a report of a new end applied without its ring; a report of a gone end that wakes no waiter | the exploration over the memory model's orders, with reports of new ends interleaved and, as a seeded failure, the ring on a report removed; a stress test of a writer and a reader that sleep on every turn, which never stalls; a read end that joins and sleeps before its writer applies the report of it, and one that waits for the reader lock before a co-reader applies the report of it, each of which wakes |
| **PI8.** The pipe server never trusts shared memory | its records of pipes, ends and holders live in Erlang, and it decides from them and from events alone: requests and notices on channels, which arrive in order from one writer each, and end records from the kernel; it touches a page others write only to free the reader lock a gone read end held, by one compare-and-swap of `owner`, which no waiter writes, and to store a new write end's number in the lock page's `wends`, which it never reads | a decision taken from a field of a ring, a reader page or the lock page | review of `erx_pipe:step/2`, which takes no shared field as input; the model's tests |

The kernel's invariants that these rest on, the pass sets that bind every
pass but a creator's, the rule that a space's table takes capabilities
only from the space itself or its creator, and the rule that no server
maps what a client can delete, are in
[design-kernel.md](design-kernel.md#invariants) (K17, K24, K25).

## Data model

### The objects of a pipe

| Object | Kind | Created and kept by | Installed into, each copy without `DUP`, `GIVE` or `DESTROY` |
| --- | --- | --- | --- |
| a lane's ring, one per write end | memory object: a 4 KiB header page and a data area of 64 KiB for a pipe's first write end, 16 KiB for every other | the pipe server | its write end, with `READ` and `WRITE`; every read end, with `READ` |
| a lane's reader page, one per write end | memory object of 4 KiB | the pipe server | every read end, with `READ` and `WRITE`; its write end, with `READ` |
| the lock page, one per pipe | memory object of 4 KiB | the pipe server | every read end, with `READ` and `WRITE` |
| a doorbell per end | IRQ object, bound by the pipe server to the holder's group with the end as its label | the pipe server | every end of the other kind and, for a read end's doorbell, the other read ends, with `TRIGGER` alone |

The first ring takes Linux's default capacity, 65,536 bytes (pipe(7)), so
a single writer runs as fast as on Linux and the programs that rely on a
large buffer keep working; every other write end's ring takes FreeBSD's
`PIPE_SIZE`, 16,384 bytes (`sys/sys/pipe.h`), since a later write end
usually carries a child's share of an inherited stream. Both are powers of
two, so positions wrap by masking, and both hold at least three records of
`PIPE_BUF` bytes (3 x 4,112 = 12,336 bytes). A pipe with one write end
and one read end takes 76 KiB of memory objects, the lane's 72 KiB and the
lock page, and two IRQ objects; every further write end adds 24 KiB and an
IRQ object, and every further read end an IRQ object. The pipe server never
deletes a page or a ring, so no holder of a pipe's memory can make another
fault. A writer that says it closed and keeps its ring mapped can go on
writing into it, which the readers ignore once they have found its lane
drained (PI2), and its ring returns to the session's budget when the
writer unmaps it or ends.

### The ring

A pipe's lane has the one layout every lane in erXos has, which
[design-domains.md](design-domains.md#connections) defines with its wake
handshake: a ring, whose header page, `erx_lane_hdr_t`, and data area the
producer alone writes, and a reader page, `erx_lane_rpage_t`, that the
consumer alone writes. Each maps the other's page read-only, so neither
can corrupt what the other publishes, and each copies every field it
reads from the other's page once and validates the copy, since the other
may write any value. For a pipe the producer is the lane's write end and
the consumer is the pipe's read side: the read end that holds the reader
lock ([The lock page](#the-lock-page)) stores the reader page's `rpos`
and `wake`.

A pipe's lane adds two pipes-specific extensions to that layout, each
where every other lane keeps zeros:

* **The stamp.** A pipe's record is an `erx_lane_rec_t` whose kind is
  `ERX_REC_DATA`, or `ERX_REC_CONTROL` for the tickets of an `SCM_RIGHTS`
  message, and whose 64-bit word that a connection's and a channel's
  records keep zero carries the record's **stamp**, the time page's
  monotonic clock in nanoseconds when the record was written. The read
  ends merge several writers' lanes in write order by it (PI6), which no
  lane with one producer needs.
* **The sleepers.** A pipe's reader page is an `erx_pipe_rpage_t`: the
  reader page of every lane, then one word, `sleepers`, that names the
  read ends waiting for data. A connection's lane has one consumer, which
  waits on one bell; a pipe's lane has up to 64 read ends, each with a
  doorbell bound to its own holder's group. `wake` tells a write end when
  to ring, and `sleepers` whom: without it, a write end would ring every
  read end at each crossing, and wake programs that hold a read end and
  do not read it.

```c
/*
 * A pipe lane's reader page: the reader page of every lane, then the
 * pipe's extension.  The read ends alone write it; the write end maps it
 * read-only and copies each field once before use.
 */
typedef struct erx_pipe_rpage {
	erx_lane_rpage_t lane;		/* rpos and wake, stored by the read
					 * end that holds the reader lock */
	_Atomic uint64_t sleepers;	/* bit r: read end r waits for data;
					 * set and cleared by read end r */
} erx_pipe_rpage_t;			/* then zeros to 4 KiB */
```

Positions count bytes since the ring was created and never wrap in
practice (2^64 bytes); a position's offset in the data area is the
position masked by the area's size. Positions, records and the area are
multiples of 16, so a record's header never straddles the end of the area,
and only its payload continues at offset 0. A pipe's records are bounded
and whole: a data record's payload is 1 to 4,096 bytes, `PIPE_BUF`, a
control record's a multiple of 8 from 8 to 128, and a write end
publishes each record whole, by one store of `wpos`, so a read end never
meets a record it cannot read to its end (PI5). A pipe's lane carries no
frames: a lane that carries frames, a connection or a program's channel,
carries each as one record of kind `ERX_REC_FRAME`, read as it is
published ([design-programs.md](design-programs.md#the-channel)). The
lane's layouts and the pipe's extension are fixed binary layouts of
`abi/erx_abi.txt`, pinned with `_Static_assert`, so `liberx`, the
session's pipe NIF and every runtime agree by construction.

Every load from a shared page goes through one function of `liberx`,
`erx_shm_copy`, which reads with relaxed atomic loads, so a holder that
writes concurrently can change what is copied but never makes the copy
undefined behaviour, and a build check fails on any other read of a lane's
or a lock page's bytes in `liberx`, the pipe NIF or a funnel. The
published positions are the exception the lane protocol makes
([design-domains.md](design-domains.md#connections)): a read end copies
a lane's `wpos`, and a write end the lane's `rpos`, with one acquire
load, which pairs with the release store that published it, before it
reads or overwrites the bytes that position covers.

**The checks.** A consumer copies `rpos` from the reader page, under the
reader lock for a pipe, then `wpos` from the ring header, then, when
`wpos` is past `rpos`, the record header at `rpos`, each once into private
memory, and `erx_ring_check`, a pure function, accepts them only if:

* `rpos <= wpos` and `wpos - rpos <= size`, both multiples of 16;
* when `wpos > rpos`: `kind` is one of the two, `len` is 1 to 4,096 for
  data and a multiple of 8 from 8 to 128 for control, and the record's
  16-byte header with `len` rounded up to 16 fits in `wpos - rpos`.

A producer keeps its write position in private memory and only ever stores
it, so nothing another holder writes moves it. It copies `rpos` and
accepts it only if `rpos <= wpos`, `wpos - rpos <= size` and `rpos` is a
multiple of 16. A read position that fails counts as a full ring: the
producer waits as for a consumer that stopped reading, so a consumer can
stop its producer but never make it fail. A reader that finds a violation
stops trusting that lane: it marks the lane **broken**, a state of its
own, treats it as gone and drained, and logs one line through the debug
log, which escapes it. The record's bytes are copied straight from the
ring into the caller's buffer, and a producer that rewrites published
bytes before they are copied changes only its own data.

### The lock page

```c
/* A pipe's lock page, shared by its read ends, which alone map it. */
typedef struct erx_pipe_lock {
	_Atomic uint32_t owner;		/* the reader lock: 0 when free, else
					 * 1 + the holder's index */
	_Atomic uint32_t wends;		/* the highest write end number made;
					 * the pipe server alone stores it */
	_Atomic uint64_t waiters;	/* bit r: read end r waits for the
					 * lock */
	uint32_t	 cur;		/* the write end whose record is
					 * claimed, by its number, or
					 * ERX_PIPE_NONE */
	uint32_t	 cur_off;	/* bytes of its payload claimed */
	uint64_t	 cur_pos;	/* the record's position in its lane */
} erx_pipe_lock_t;			/* then zeros to 4 KiB */
```

Read ends share this page as POSIX processes share a pipe's read side, so
a hostile co-reader can disturb the stream it shares, never another
party's memory. The lock's holder and its waiters are separate words, so a
waiter that registers never writes the word that names the holder, and
whoever frees the lock does it with one store or one compare-and-swap. A
reader checks the holder index in `owner` below 64.

`wends` is the pipe's count of write ends made: before the pipe server
installs a write end's capabilities anywhere, into a reader, a child or a
deposit, it stores the end's number there with release order, so every
record any write end publishes was written after its number reached the
page. A read end keeps its own count of the write ends it knows of,
which its install names, as the pipe's `wends` at that moment, and each
`{pipe_writer}` report it applies raises, and compares the two
([Reading and merging](#reading-and-merging)).
The pipe server writes it and never reads it (PI8); a co-reader that
rewrites it can make the readers of its own stream wait for a report
that never comes, or lose write order between them, as it could by
holding the reader lock, and nothing else.

The **current record** is the record at `cur_pos` in the lane of write end
`cur`, and `cur_off` counts the bytes of its payload that readers have
claimed. A reader that takes the lock settles it before it picks anything
else, by the first row that matches what it copied:

| The reader finds | Which means | The reader |
| --- | --- | --- |
| `cur` names a write end whose lane it holds, that lane's `rpos` equals `cur_pos`, and `cur_off` is below the record's length | a reader released the lock, or ended, inside the record | continues the record from `cur_off` |
| the same, with `cur_off` at the record's length | a reader ended after claiming the record's last bytes | retires the record whole: advances `rpos` past it, discards a control record's tickets, and sets `cur` to none |
| that lane's `rpos` past `cur_pos` | a reader finished the record and ended before it set `cur` to none | sets `cur` to none |
| anything else | no record is current, or `cur` names a lane the reader does not hold or a value out of range | sets `cur` to none |

So a record whose bytes a reader has claimed is never read from its start
again, and a record no reader claimed is never retired. A page that reads
zeros, as a fresh one does, has a free lock and names no current record,
since write ends are numbered from 1.

### Ends in `liberx`

A pipe end is one of the descriptor kinds of a program's descriptor table
([design-programs.md](design-programs.md#descriptors-and-files)):

```c
typedef struct erx_pipe_end {
	erx_pipe_kind_t	 kind;		/* ERX_PIPE_READ or ERX_PIPE_WRITE */
	uint32_t	 pipe;		/* the pipe server's names */
	uint32_t	 end;
	bool		 nonblock;	/* O_NONBLOCK: this program's own */
	bool		 lost;		/* the pipe server ended */
	union {
		erx_pipe_wend_t	 w;	/* its lane, mapped; its private write
					 * position; its count of read ends;
					 * the read ends' doorbells by index,
					 * at most 64 */
		erx_pipe_rend_t	 r;	/* its index and the lock page; per
					 * write end, by number: the lane,
					 * whether its writer is open or
					 * gone, the writer's doorbell and the
					 * lane's batches; the other read
					 * ends' doorbells by index */
	} u;
} erx_pipe_end_t;
```

The `kind` selects the member, and only accessors that check it touch the
union. A program's `dup` makes two descriptors of one end object; the end
object lives while a descriptor or a call in progress holds it, and its
mappings and capabilities close with its last reference, after which
`liberx` sends its handler the notice `{closed, Pipe, End}`. An end's own
tables are guarded by the end object's lock, which a call holds while it
uses them and the event executor holds while it applies a report, never
across a wait.

### The pipe server's records

```erlang
-record(pipe, {id :: pos_integer(),
               lock :: cap(),                       % the lock page
               writers = #{} :: #{wend() => #writer{}},
               readers = #{} :: #{rix() => #reader{}},     % at most 64
               next_wend = 1 :: pos_integer(),      % never reused in a pipe
               deposits = #{} :: #{ticket() => deposit()}}).  % 16 a write end
-record(writer, {holder :: holder(), ring :: cap(), rpage :: cap(),
                 size :: 16384 | 65536, doorbell :: cap(),
                 state :: open | {gone, [rix()]}}). % read ends not yet drained
-record(reader, {holder :: holder(), doorbell :: cap()}).
%% wend() = a write end's number; rix() = 0..63; cap() = a capability of
%% the session's table; holder() = {program, Pid}, a program of the
%% session by its process id, {process, pid()}, a process of the session,
%% or {deposit, ticket()}, for an end held for a ticket; ticket() = 64
%% random bits; deposit() = the end or the grant held for one ticket, with
%% the write end it was made through
```

The records are the truth about every pipe of the session; `erx_pipe:step/2`
computes every change from them and an event, and the pipe server applies
the actions it returns ([The pipe server](#the-pipe-server)). The lock
page's `wends` is `next_wend - 1`, stored at each write end's creation. A
writer that is gone stays in the records, with the read ends that have
not yet reported its lane drained, until that list is empty; then the
pipe server closes its capabilities to the lane and forgets the write end.

## Algorithms and behavior

### Writing

`erx_pipe_write(end, buf, len)` splits `len` into chunks of at most
`PIPE_BUF` bytes, each one record, and for each chunk:

1. **Check the read side.** It reads its own count of read ends and its
   `lost` flag, which the event executor keeps from the handler's reports
   under the end's lock. A lost pipe, or a count of zero, fails the call
   with `EPIPE`, and `liberx`'s signal machine sends the calling thread
   `SIGPIPE`, as POSIX requires
   ([design-programs.md](design-programs.md#signals-in-liberx)).
2. **Find room.** It copies `rpos` from the reader page and checks it; the
   record needs its 16-byte header and its payload rounded up to 16, beside
   any room that a `sendmsg` on the same end holds reserved for its control
   record (below). Without room, or with a read position that fails the
   check, an `O_NONBLOCK` end fails with `EAGAIN` if it has written nothing
   yet, and otherwise returns the count written, which for a write of at
   most `PIPE_BUF` bytes is never partial, since it is one record. A
   blocking end publishes in the ring header's `need` the read position
   at which the room it needs is free, `wpos + bytes - size` for `bytes`
   of room, which covers the whole record since a pipe's record is
   published whole, executes a full fence, checks the read side and room
   again, and waits for its doorbell. A signal ends the wait as
   the personality's signal rules say, returning the count already written
   if there is one.
3. **Copy.** It writes the record's header, with the time page's monotonic
   clock as `stamp`, and the payload into the data area at its write
   position, continuing at offset 0 at the end of the area.
4. **Publish.** It stores the next `wpos` with release order, executes a
   full fence and copies `wake` and `sleepers` from the reader page; if
   its store moved `wpos` from below `wake` to `wake` or past it, it rings
   the doorbell of each read end whose bit in `sleepers` is set.

So a record is visible whole or not at all, and a writer that ends between
steps 3 and 4 leaves nothing a reader sees. A writer rings only the read
ends its handler has reported to it; a read end that joined and set its
bit before the writer applied the report of it is rung when the writer
applies that report ([Waiting and doorbells](#waiting-and-doorbells)).

### Reading and merging

`erx_pipe_read(end, buf, len)` works under the pipe's **reader lock**, the
lock page's `owner` word:

1. **Take the lock** with a compare-and-swap of `owner` from 0 to
   `1 + rix`. While another read end holds it, the reader sets its bit in
   `waiters` with an atomic or, executes a full fence and tries again; if
   the lock is still held, it waits for its doorbell and starts over,
   clearing its bit when it wakes. It waits even under `O_NONBLOCK`, as
   Linux waits for its pipe's mutex, since the lock is held only for a copy
   or a redemption.
2. **Bring the lane set up to date.** Under the end's lock it takes the
   changes the event executor applied from the handler's reports: a lane
   that joined, which it maps if it has not yet; a writer that is gone,
   whose lane it will drain; and a lane it has drained after its writer
   went, which it unmaps and closes, sending the handler
   `{drained, Pipe, End, Writer}` once. A lost pipe fails the read with
   `EIO`.
3. **Settle the current record** as [The lock page](#the-lock-page) says:
   the read continues it from `cur_off`, or retires it, or finds none.
4. **Pick the next record.** Otherwise, for every lane it holds, it reads
   the clock and then, ordered after the reading, copies the lane's `wpos`
   with acquire order and, when the lane is not empty, its first record's
   header, and checks them. If any lane holds a record, it copies the
   lock page's `wends` and, when that is above its own count of write
   ends ([The lock page](#the-lock-page)), takes up, as in step 2, every
   lane the event executor applied meanwhile. If `wends` is still above
   its count, the report of a write end it does not know is on its own
   channel: it releases the lock, waits until its event executor applies
   the report, which wakes it, even under `O_NONBLOCK`, as for the lock,
   and starts again. It then reads the clock and copies `wpos` again for
   each lane it found empty and each lane it took up. A record's
   **order key** is the larger of its stamp and its **mark**, the clock's
   reading before the last copy of its lane's `wpos` that did not include
   it, which the reader keeps in the lane's batches (below); the reader
   takes the record with the smallest key, the lowest write end number
   first on a tie.
5. **Copy.** It first records in `cur`, `cur_off` and `cur_pos` the record
   and the bytes it takes, then copies them into `buf`, in two parts when
   the payload continues at the start of the area.
6. **Finish a record.** A record read to its end advances the lane's
   `rpos` past it with release order and sets `cur` to none; after a full
   fence the reader copies `need` from the ring header, and if its store
   moved `rpos` from below `need` to `need` or past it, rings that
   writer's doorbell. The read goes on with the next record
   until `buf` is full or nothing is readable; a record that does not fit
   stays current for the next read, by this read end or another.
7. **End of stream or wait.** When nothing more is readable, a read that
   copied something returns its count. One that copied nothing returns 0,
   the end of the stream, if it holds no lane whose writer is open and
   every lane whose writer is gone is drained or broken. A read end that
   has found such a lane drained counts it drained from then on, whatever
   the ring shows later, so the end of the stream comes once. Otherwise an
   `O_NONBLOCK` end fails with `EAGAIN`, and a blocking one sets its bit
   in `sleepers` and stores `wake = rpos + 1` in every open lane's reader
   page, executes a full fence and picks again; if still nothing is
   readable, it releases the lock, waits for its doorbell, clears its bits
   when it wakes, and starts again.
8. **Release the lock** by storing 0 in `owner` with release order; then,
   after a full fence, it copies `waiters` and rings the doorbell of each
   read end whose bit is set.

**Batches.** A reader keeps, for each lane, a queue of at most four
**batches**, each the end position of bytes it found at one copy of the
lane's `wpos` and that batch's **mark**. A copy that ends past the lane's
newest batch opens a batch ending there, marked with the clock's reading
taken before the reader's previous copy of that `wpos`, its last look at
the lane without those bytes; a lane's first copy opens a batch marked 0.
A batch closes when the reader has read past its end. A batch never grows:
while a lane has four open batches, step 4 copies no `wpos` of it and
picks from those batches alone, so bytes published meanwhile open a batch
at the first copy after the oldest batch closes, marked with the reading
before the last copy made, which did not include them either.

For example, writer A publishes a record stamped 100 while writer B's ring
is empty. The reader reads the clock at 105 and copies both lanes' `wpos`,
finding A's record and B's ring empty. Writer B then publishes a record it
stamped 90. Having found a record, the reader reads the clock again and
copies B's `wpos`, finds B's record, and opens a batch marked 105. B's key
is 105 and A's 100, so A's record, which the reader saw before B's was
published, is read first, and B's early stamp gains it nothing. Had B's
record been in its ring at the copy at 105, it would belong to an older
batch with an older mark, its key would be 90, and it would be read first,
as it was written first.

**Control records.** A record of kind control carries the tickets of an
`SCM_RIGHTS` message, which `sendmsg` publishes together with the
message's first data record, by one store of `wpos`, so a ring never holds
a control record without the bytes it comes with. `sendmsg` waits for room
for both records, as a write waits, and reserves it in its end before it
deposits anything, so its deposits are published as soon as their tickets
come ([design-programs.md](design-programs.md#passing-descriptors)). A
control record and the data record after it are one **merge unit**:
`sendmsg` stamps both with one reading of the clock, the merge orders the
unit by the control record's key, and a reader that takes the control
record takes the data record after it in the same lane next, without
picking again, so the descriptors come with their own message's bytes and
never with another writer's that the merge would have put between them.
The control record's payload never reaches `buf`, and `POLLIN` and
`FIONREAD` count data records alone. A reader that meets a control record
enters its closed region before it claims it, so during an `exec`'s
quiesce it releases the reader lock and waits at the region's entry,
leaving the record unclaimed
([design-programs.md](design-programs.md#signals-in-liberx)). A `recvmsg`
with room for descriptors that meets one before it has copied bytes claims
it whole, redeems its tickets, and only then retires it and reads on, all
under the reader lock, so the descriptors come with the bytes that follow
them, and the pipe server has answered every redemption of a lane's
tickets before any read end can report that lane drained
([Deposits](#deposits)). The waits for the redemptions' replies are closed
waits ([design-programs.md](design-programs.md#signals-in-liberx)): no
signal handler runs there, `siglongjmp` cannot leave them and `exec` does
not park the thread there, so nothing keeps the reader lock past their
end; each ends at its reply, which the handler gives once the end is
installed or the request has failed. A redemption that fails leaves its
descriptor out, and `recvmsg` reports `MSG_CTRUNC`, as Linux does for a
descriptor it cannot install. A `recvmsg` that has copied bytes ends its
data before the control record. A `read`, or a `recvmsg` without room for
descriptors, claims it in the same way, retires it, releases the reader
lock and sends its handler the request `{discard, Stream, Ticket}` for
each ticket, waiting for each reply in its closed region, so a ticket
skipped is let go of once. A record's kind is in its header, which only
its own writer's ring carries, so no bytes a writer writes as data are
ever taken for tickets.

**Why the order key keeps write order.** Of two writes where one happened
before the other, say the last line of `date` and the first of `uname` in
`{date; uname} | cat`, the first was published before the second was
written, so its stamp is smaller. The earlier record's write end had its
number stored in `wends` before its holder could run, so before the later
record existed; a reader that sees the later record has acquired its
lane's `wpos`, so its copy of `wends` reaches the earlier write end, and it
picks only once it holds that lane, which it then loads with every lane it
found empty; so it finds the earlier record whenever it finds the later
one. A raised stamp stays below the stamp of every write made after its
record was published, since the reader read the clock before a copy that
did not yet see the record, so writes that happened one after the other
keep their order.

**Why no writer starves another.** With one read end, a record stamped
when it was written waits behind at most two lanes' capacity of each other
writer's bytes published after it. Such bytes are read first only if their
batch's mark is below the record's key, which is below the record's
publication. A batch is marked with the reading before the previous copy
of its lane, so such a batch was opened by one of the two copies of that
lane around the record's publication: the last copy whose reading came
before it, or the first whose reading came after. A batch never grows, so
each holds at most one ring's capacity. A writer that stamps every record
0 and never lets its ring empty therefore delays another writer's record
by at most 128 KiB of its own later bytes, and with `n` open write ends a
record waits behind at most 32 KiB for each of the others, the first ring
being 64 KiB and the rest 16 KiB; each further read end that reads
meanwhile adds at most as much again.

**Losing bytes to a reader's end.** Claiming bytes in the lock page before
copying them means a reader that ends in the middle of a read loses what
it was taking, as a UNIX process killed inside `read` does; ring space is
freed only after the copy, so a writer never overwrites bytes a reader is
still copying.

### Waiting and doorbells

Every wait of a pipe is a wait for the end's doorbell: a worker sleeps on
its wake word and the event executor wakes it when the end's label comes
up in the group's ready list
([design-programs.md](design-programs.md#the-event-executor)); the
session's pipe NIF returns `would_block` instead
([The session's pipe NIF](#the-sessions-pipe-nif)). Three things say who
waits, each written by the party that waits, in a page it writes, and
read by the party that rings it:

| What the waiter publishes | Published by | Read, and rung on, by |
| --- | --- | --- |
| a ring header's `need` | its write end, waiting for room | the read end whose store of `rpos` crosses it |
| a lane's `wake`, and bit `r` of its `sleepers` | read end `r`, waiting for data | the write end whose store of `wpos` crosses `wake`, which rings each read end whose bit is set |
| bit `r` of the lock page's `waiters` | read end `r`, waiting for the lock | the read end that releases the lock |

The first two are the wake handshake of every lane
([design-domains.md](design-domains.md#connections)), with `sleepers` to
say whom to ring, and all three follow one pattern (PI7): the waiter
publishes what it waits for, executes a full fence and checks again
before it waits; the other party makes its change, executes a full fence,
reads what the waiter published, and rings only when its change reached
it: a store of a position that crossed the published one, or a release of
the lock with a waiter's bit set. A read end clears its bits when it
wakes; a published position needs no clearing, since a position already
crossed is never rung again. Since only the waiter writes what it
publishes, each party writes only its own page. A bit still set after its
waiter woke costs at most one needless trigger, and triggers that come
before a wait count once, so a peer that rings needlessly costs the
holder at most one wake for each of its waits. A read end that takes an
index first clears its bits in every lane's `sleepers` and in `waiters`,
since a read end that held the index before may have ended with them set.

**A new end is rung once.** A party can ring only the doorbells its
handler has reported to it, and a new end's holder can run, and wait,
before every peer has applied the report of it: a read end that joins can
set its bit in `sleepers` or in `waiters` before the writer whose store
crosses `wake`, or the co-reader that releases the lock, knows its
doorbell, and since a position is crossed once, that reader would sleep
for good. So every party that applies a report of a new open end,
`{pipe_writer}` or `{pipe_reader}`, rings that end's doorbell once as it
applies it, and the new end's waiter wakes and checks again. The rule is
the same for both kinds, though a new write end needs it less, since no
reader can cross its `need` before it knows the lane; the ring costs at
most one needless wake.

**Who makes a doorbell.** The pipe server makes an end's doorbell when it
makes the end, with the session's budget, and binds it to the holder's
group with the end as its label: a program's group, which the session
created and holds the right to signal on, or the session's own group for
an end a session process holds, where the runtime delivers the label to
the owning process as a message
([design-runtime.md](design-runtime.md#the-device-nif)). It installs
`TRIGGER` on it, and nothing more, into every peer that rings it: a write
end's doorbell into every read end's holder, and a read end's doorbell
into every write end's holder and every other read end's. It does so
before the end's holder can wait on it: for a child, before the child's
first thread starts; for an end made for a running program, by `pipe` or
a redemption, before the request's reply; and for the peers of a new end,
before it tells them of the end. A holder never receives a copy of a
doorbell of its own: `liberx` rings its own ends of a pipe through the
copies it holds for the peer end, which for a pipe whose ends one program
holds are the program's own doorbells, so such a pipe costs no install
beyond the program's. A holder keys the doorbells it rings by the peer
end, a write end by its number and a read end by its index. When an end
goes, the pipe server tells each peer, which closes its copy, and closes
its own; the IRQ object goes with the last capability, and a ring of a
deleted doorbell fails with `ERX_ESTALE`, which a ringer that has not yet
applied the report ignores.

### Ends and their holders

A write end holds its lane, mapped, and the trigger right on every read
end's doorbell. A read end holds every lane of the pipe, the lock page,
the trigger right on every write end's doorbell and on every other read
end's. When an end object's last reference goes, `liberx` releases its
mappings, closes its capabilities and sends its handler the notice
`{closed, Pipe, End}`. When a program ends, however it ends, its handler
sees the end record of its space and tells the pipe server that every end
the program held is gone
([design-programs.md](design-programs.md#a-programs-end)); a session
process's ends go when the process exits, as the pipe NIF's resources do.
The pipe server then:

* for a **write end**: marks it gone, with the pipe's read ends as the
  ones that have not yet drained its lane, or forgets it at once when no
  read end remains; closes its capability to the end's doorbell; and tells
  every read end's holder `{pipe_writer_gone, Pipe, End, Writer}`;
* for a **read end**: frees the reader lock if that read end held it, by
  one compare-and-swap of `owner` from `1 + rix` to 0, since a gone holder
  cannot release it and no waiter writes `owner`; closes its capability to
  the end's doorbell; frees the index; tells every write end's holder and
  every other read end's holder `{pipe_reader_gone, Pipe, End, Rix}`; and
  removes the index from every gone writer's list of read ends not yet
  drained.

A read end that drains a gone writer's lane unmaps and closes its copies
and reports `{drained, Pipe, End, Writer}`; the pipe server removes it
from the writer's list, and when the list is empty closes its own
capabilities to the lane and forgets the write end, so the lane's memory
returns when its last holder, the gone writer included, has let it go.
A program sends each `{closed}` and `{drained}` once, for an end it was
given and a writer it was told is gone, and the port driver ends a program
that sends one that is not due
([design-programs.md](design-programs.md#the-program-protocol)); the pipe
server still ignores a report from a holder of no read end of the pipe,
or about a write end that is open or unknown. When no end of either kind
remains, the pipe server closes every capability it holds for the pipe
and forgets it.

### Making a pipe

A program's `pipe` and `pipe2` send `{pipe, Flags}` to its handler, which
passes the request to the pipe server:

1. **Plan.** `erx_pipe:step/2` checks the session's `pipes` quota and
   returns the objects to make: the lock page, a lane of 64 KiB, and two
   doorbells.
2. **Make.** The pipe server creates them with the session's budget and
   binds each doorbell to the program's group with its end as the label.
3. **Install.** The handler installs into the program's table, through the
   port driver, the copies each end needs: for the read end, the lane's
   ring with `READ`, its reader page with `READ` and `WRITE`, the lock page
   with `READ` and `WRITE`, and `TRIGGER` on the write end's doorbell; for
   the write end, the ring with `READ` and `WRITE`, the reader page with
   `READ`, and `TRIGGER` on the read end's doorbell
   ([design-programs.md](design-programs.md#the-handler)).
4. **Reply** `{ok, Read, Write}`, each a descriptor naming the values in
   the program's table; `liberx` maps the pages and from then on rings the
   two ends itself.

A failure undoes the steps before it: the objects close, and `pipe` fails
with `ENFILE` at the session's quota, `EMFILE` when the program's table
cannot take the ends, and `ENOMEM` for the session's budget or the
program's. The session's own processes get their pipes the same way,
without an install, since the capabilities stay in the session's table.

### Inherited ends

A program never hands its own end to another program. When a spawn or a
fork names a descriptor that is a pipe end, the request names that end,
and the pipe server makes an end of the same kind for the child
([design-programs.md](design-programs.md#starting-a-program)), after
checking that the requester holds the end (`EBADF` otherwise). The ends a
pipe gains proceed side by side, for one child or for several: none waits
for another end or for a child's creation, so a `pipe` followed by a
`fork` that hands both ends to the child, or a pipeline whose stages share
a pipe, never waits on itself:

* **A write end** for the child takes the pipe's next number, a lane of 16
  KiB and a doorbell bound to the child's group. The pipe server first
  stores the number in the lock page's `wends`, then installs into each
  read end's holder the lane and the doorbell's trigger right and tells it
  `{pipe_writer, Pipe, End, Writer, Ring, RPage, Size, Doorbell, open}`,
  and hands the child's handler the child's copies: its lane and `TRIGGER`
  on every read end's doorbell. The new end publishes from its first write
  and waits on no reader's event executor: a reader that meets a record
  while `wends` names a write end it has not yet been told of waits for
  that report, which is already on its own channel, before it picks
  ([Reading and merging](#reading-and-merging)). A pipe takes any number
  of write ends: what bounds them is the session's `pipes` quota, which
  counts lanes, and its budget. A writer that finds no room in its own
  ring waits for the reader, as a UNIX writer does; no creation ever waits
  on a reader. Each write end puts three capabilities into every read
  end's holder, its ring, its reader page and its doorbell, which stay
  there until the lane is drained, so a reader that drains nothing, a
  paused pager among them, holds them for every write end that joins; the
  session's policy therefore sizes each program's budget, which pays for
  its capability table and its mappings, for three capabilities and one
  lane's mappings for every lane the `pipes` quota allows, beside the
  program's own needs, and no install into a reader fails within the quota
  ([Security](#security)).
* **A read end** for the child takes a free index and a doorbell bound to
  the child's group. The pipe server installs the doorbell's trigger right
  into every write end's holder and every other read end's and tells each
  `{pipe_reader, Pipe, End, Rix, Doorbell, open}`, and hands the child's
  handler the child's copies: every lane, the lock page, and `TRIGGER` on
  every write end's and every other read end's doorbell, with the pipe's
  `wends` as it stands for the end's own count of write ends. A read end
  beyond 64 fails the spawn or fork with `EMFILE`.

The child's copies are installed into the child's table before its first
thread runs, among the installs of its creation, and its startup or fork
message names their values; the pipe server records the child as the
end's holder when it makes the end, since the child's handler undoes the
end if the creation fails. So every holder of an end holds, before it can
run, every lane and doorbell its end needs, and every peer holds the new
end's before the new end's holder can run (PI7). If the creation fails,
the child's handler tells the pipe server the end is gone, and the other
ends see it come and go. The shell's own pipelines need no inheritance:
the pipe server makes each end for the program that uses it
([design-shell.md](design-shell.md#pipelines)).

### Readiness, `poll` and `select`

Each end's doorbell is bound to its holder's group, labelled with the end,
so the group's ready list names exactly the ends rung since the event
executor last looked, and the executor evaluates only those, and the ends
whose reports it applied
([design-programs.md](design-programs.md#the-event-executor)):

| End | `POLLIN` | `POLLOUT` | `POLLHUP` | `POLLERR` |
| --- | --- | --- | --- | --- |
| read | a lane holds a data record | never | no write end is open, or the pipe is lost | the pipe is lost |
| write | never | its ring has room for a record of `PIPE_BUF` bytes | never | no read end remains, or the pipe is lost |

`POLLHUP` comes with `POLLIN` while records remain after the last writer
went, and alone once they are read, and a write end with no read end
reports `POLLERR`, as Linux's `pipe_poll` does. `FIONREAD` walks the
records of the read end's lanes under the reader lock and reports the
payload bytes of their data records, less what the current record has
given.

### Closing in one thread while another reads or writes

The descriptor table's rule applies
([design-programs.md](design-programs.md#descriptors-and-files)): `close`
empties the slot at once and the end object lives while a call holds it,
so a read or write in progress finishes as on Linux, and the end's
mappings and capabilities close with the call's reference. A blocked read
or write wakes only for its doorbell: data, room, the reader lock, a
report, the end of the stream, no read end remaining, or a signal.

### The pipe server

`erx_pipe_srv` is a process of the session's command server. Its decisions
are one pure function, `erx_pipe:step(State, Event) -> {State, [Action]}`;
the process performs the actions with the pipe NIF, the port driver and the
handlers:

| Event | Actions |
| --- | --- |
| `{pipe, Holder, Flags}` | within the session's `pipes` quota, make a pipe's lock page, lane and two doorbells; install each end's copies into the holder; reply |
| `{inherit, Holder, End, Child}` | if `Holder` holds `End`: make an end of the same kind for `Child`, a write end with a lane and a doorbell, its number stored in the lock page's `wends` before any install, a read end with an index and a doorbell, or fail with `emfile` at the 65th read end; install into every peer what it needs of the new end and tell it; return the new end's copies for the child's creation; ends of one pipe never wait for each other |
| `{closed, Holder, End}` | if `Holder` holds `End`: the steps of [Ends and their holders](#ends-and-their-holders) |
| `{gone, Holder}` | the same for every end `Holder` holds |
| `{drained, Holder, End, Writer}` | if `Holder` holds the read end `End` and `Writer` is gone with `End`'s index in its list: remove the index, and when the list is empty close the capabilities to the lane and forget the write end |
| `{exec, Program, NewImage, Kept}` | for each end of `Program` that `Kept` names by descriptor: install into `NewImage` fresh copies of everything the end holds, from the pipe server's own capabilities, and return the values for the new image's startup message, with the pipe's `wends` for a read end; record the new image as the holder; the old image's copies go with its table ([The second tier](#the-second-tier)) |
| `{deposit, Holder, Descriptor, Stream}` | if `Holder` holds the write end `Stream`, and fewer than 16 deposits made through `Stream` are open (`etoomanyrefs` otherwise): for `{pipe, End}`, an end `Holder` holds, make an end of the same kind, held by the deposit, telling the pipe's other holders as for an inherited end; for `{socketpair, ReadEnd, WriteEnd}`, one of each; for a file, terminal or directory descriptor, keep the open it names; hold them as one deposit under a fresh ticket of 64 random bits, made through `Stream`, and reply with the ticket |
| `{redeem, Holder, Stream, Ticket}` | if `Holder` holds the read end `Stream` of the pipe `Ticket` was deposited on and the ticket is unredeemed: install the deposit's end into `Holder`, with every lane and doorbell the end needs and, for a read end, the pipe's `wends`, and record `Holder` as its holder, or hand on the held open, and reply with the descriptor; an install that fails fails the request, and the end is gone |
| `{discard, Holder, Stream, Ticket}` | if `Holder` holds the read end `Stream` of the pipe `Ticket` was deposited on: close the deposit if it is open; reply `ok` either way |
| `{withdraw, Holder, Stream, Ticket}` | if `Holder` holds the write end `Stream` and `Ticket` was deposited through it: close the deposit if it is open; reply `ok` either way |
| an end gone, or a deposit made or closed | close the deposits no reader can reach ([Deposits](#deposits)) |
| the last end of a pipe gone | close every capability held for the pipe and forget it |

**Holders.** A program's handler forwards each request and notice of its
program with the program as `Holder`: the handler serves one program and
one image at a time, and the channel the frame arrived on names both, so
no field of a frame says who asked
([design-programs.md](design-programs.md#the-channel)). A session process
that calls the pipe NIF is its own holder. The pipe server installs into a
program only through that program's handler, which installs by the
session's own capability to the image it serves, so no value is ever
installed into a table other than the one it was meant for
([design-programs.md](design-programs.md#invariants), P11).

**A crash of the pipe server.** The pipe's objects are resources the pipe
server's process owns, and when it exits their destructors close the pipe
server's capabilities, deleting no memory. Each program learns of the loss
from its own handler: every handler monitors the pipe server it forwards
to and, when it goes, sends its program `{pipe_server_lost}` before it
forwards anything to the restarted one, and `liberx` counts every pipe end
it then holds lost and wakes every worker waiting on one. Every session
process that holds an end gets the same message. Every party, woken, finds
its pipe lost, so its reads fail with `EIO` and its writes with `EPIPE`,
never a false end of stream and never a fault, and each page and ring
returns to the session's budget when the last party has closed its end.
The supervisor restarts the pipe server for later pipes. A pipe's
structure never depends on a program's honesty: a program can only hold
its ends, close them, ask for ends for its children, report drained lanes,
and deposit, withdraw, redeem and discard ends, and a false report harms
only the stream its own read end shares.

### The session's pipe NIF

The session's terminal relay, its Erlang commands and the stream relays of
its command domains hold ends that the pipe server made for them, through
the pipe NIF
([design-runtime.md](design-runtime.md#the-console-and-standard-io)). The
NIF reads and writes lanes exactly as `liberx` does, without ever waiting,
so executors may call it: where a program's call would wait, for data,
room, the reader lock or a write end's report, the NIF publishes the same
position or bit, if any, and returns `would_block`, and the process waits
for a message: the doorbell's label, which the runtime delivers to the
end's owner when the doorbell rings, or the pipe server's report. An end
is a resource owned by one process, and it is gone when that process
exits. The command image, which runs an Erlang command or `rc` in a
command domain, holds no end of a session's pipe: its standard streams are
relayed by its session
([design-programs.md](design-programs.md#what-a-program-can-start)).

### The second tier

* **`fork`** gives the child an end of its own for each pipe end of the
  parent's descriptor table, made by the pipe server when the handler
  handles the `fork` request and installed into the child after the copy
  of the parent's space, before the child runs; the fork message names the
  ends' values ([design-programs.md](design-programs.md#fork)). The copy
  leaves out every pipe capability, since none carries `DUP`, and every
  mapping of a pipe's memory, which no one creates to be inherited, so the
  child never maps its parent's lanes, and each lane keeps one writer
  (PI4)
  ([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
* **`exec`** keeps every descriptor without `FD_CLOEXEC`: the old image
  names each kept end by its descriptor in its `{exec}` request, and the
  pipe server installs into the new image fresh copies of everything the
  end holds, from its own capabilities: every lane the end needs, open or
  gone and not yet drained, the lock page and the doorbells
  ([design-programs.md](design-programs.md#exec)). The new image takes a
  write end's private position from its handover, never from the ring,
  maps the pages, and keys the lanes by the write end numbers its startup
  message gives, each marked open or gone. The old image's copies, and its
  mappings, go with its table; the end's own doorbell stays bound to the
  program's group, which survives `exec`, so no peer changes anything.
* **Passing a descriptor** with `SCM_RIGHTS` hands a pipe end on as an end
  of its own. The sender's `liberx` deposits the end with the pipe server,
  naming the stream it sends on, a write end it holds; the pipe server
  makes the end at once and holds it for a ticket, so the end counts as a
  holder while it is in flight and a pipe in flight is never closed, as a
  descriptor in flight on UNIX keeps its file open. The sender writes the
  ticket into the stream as a control record ([Reading and
  merging](#reading-and-merging)); whichever read end of that stream meets
  it in `recvmsg` redeems the ticket, and the pipe server installs the end
  into that read end's program, as UNIX gives the descriptor to whichever
  process reads the message, while a `read` that skips it discards the
  ticket. The sender keeps its own end, as on UNIX, and no capability
  passes between the programs
  ([design-programs.md](design-programs.md#passing-descriptors)).
  [Deposits](#deposits) gives a deposit's whole lifetime, the limit of 16
  for each write end, and the collector of deposits no reader can reach.

### Deposits

A **deposit** holds one descriptor that an `SCM_RIGHTS` message passes,
under one ticket: a pipe end made for the deposit, one end of each kind
for a socketpair, or the open of a file, terminal or directory. An end in
a deposit is a holder like any other to the pipe's other ends: its lane
joins the readers, or its doorbell the writers, when it is made, and the
program that redeems it receives everything the end needs at redemption.
An open in a deposit is the sender's handler's open until it is redeemed,
when the redeemer's handler takes it over as a pass grant of its own, and
closing a deposit closes it
([design-programs.md](design-programs.md#passing-descriptors)). A deposit
lasts from the sender's `{deposit}` until the first of these:

* a read end of its stream redeems it or discards it;
* the write end it was made through withdraws it, as `sendmsg` does when
  it cannot publish the ticket, after another of the message's deposits
  failed or the room it reserved was lost to a co-reader's rewrite of
  `rpos`;
* the lane of the write end it was made through is reported drained by
  every read end after that write end went: no record of a drained lane
  can carry the ticket any further, and the pipe server has answered every
  redemption of a ticket that lane carried, since a read end redeems a
  control record's tickets before it releases the reader lock ([Reading
  and merging](#reading-and-merging));
* no reader can reach it, as the collector below decides.

So a deposit outlives the write end it was made through only while its
ticket may be in that lane, and a deposit whose ticket was never published
closes when its sender withdraws it or once its sender's lane is drained,
whatever became of the sender. Each write end holds at most 16 open
deposits, its own share of the pipe's, and a `{deposit}` beyond them
fails, so a sender that keeps its end and neither publishes nor withdraws
spends only its own share and never denies another writer of the stream.

The **collector** closes the deposits that no reader can reach. A pipe is
**reachable** when a read end of it is held by a program or by the
session, is being made for a program, or is held in a deposit on a
reachable pipe. After any change to those holdings, an end gone or a
deposit made or closed, the pipe server runs one pass over the pipes that
hold deposits, and none while the session holds no deposit: it marks each
such pipe with a read end of the first two kinds, then each one a read end
of which is held in a deposit on a marked pipe, until no pipe gains a
mark, and closes every deposit on a pipe left unmarked. A chain of
reachability runs only through pipes that hold deposits, so the pass
misses none; each pipe is marked at most once and each deposit followed at
most once, so a pass takes time in proportion to the session's deposits,
not its pipes. A socketpair's end sent over itself and closed is
unreachable and closes, as Linux's collector of such cycles finds it,
while a read end queued on another stream that a program reads keeps every
deposit on its own pipe.

### The pipe core

The writer's and the reader's steps are pure functions in `liberx`,
`erx_pipe_wstep` and `erx_pipe_rstep`, over an end's private state and the
copies it took of shared fields, returning the stores, copies, fences,
rings and waits to perform; `erx_ring_check` validates what a consumer
copied. They build for the host, where a model of one pipe in two shapes,
three write ends with two read ends and two write ends with three read
ends, with rings of 128 bytes, records of at most 16 bytes, `PIPE_BUF`
scaled down with them, and at most two batches a lane, runs through every
interleaving of writes, reads, inherited ends, closes, holders' deaths,
drained reports, deposits, redemptions and withdrawals, reports applied
late by a reader's event executor while `wends` already names their write
ends, hostile
rewrites of shared fields, the pipe server's crash, and the reorderings
the fences allow, up to 14 events (an estimate of what fits `make check`'s
budget), and checks PI2 to PI7 and the service bound after every event.
`erx_pipe:step/2` is explored the same way over its events, with PI1 and
PI8 added, and its collector is checked against a model of reachability
over random holdings of ends and deposits, chains and cycles among them.
This is the pipe core the style guide lists among the protocols explored
exhaustively ([style.md](style.md#functional-core)).

## Interfaces

### `liberx`

The POSIX functions `pipe`, `pipe2` (`O_CLOEXEC`, `O_NONBLOCK`), `read`,
`readv`, `write`, `writev`, `close`, `dup`, `dup2`, `poll`, `select`,
`fcntl` (`F_GETFL` and `F_SETFL` with `O_NONBLOCK`), `ioctl` (`FIONREAD`),
`fstat` (`S_IFIFO`) and `lseek` (`ESPIPE`) act on pipe ends through four
functions of the personality:

```c
/* Write len bytes; EAGAIN, EPIPE or EINTR as POSIX says for pipes. */
ssize_t	erx_pipe_write(erx_pipe_end_t *end, const void *buf, size_t len);

/* Read at most len bytes; 0 at the end of the stream, EIO once lost. */
ssize_t	erx_pipe_read(erx_pipe_end_t *end, void *buf, size_t len);

/* The POLL* bits the end reports; never waits. */
short	erx_pipe_poll(erx_pipe_end_t *end);

/* Drop a reference; the last releases the end's mappings and capabilities. */
void	erx_pipe_release(erx_pipe_end_t *end);
```

Each is safe to call from any thread of the program; `erx_pipe_write` and
`erx_pipe_read` may wait, so only workers call them, and the event
executor never does.

### The program protocol

Messages between a program and its handler on the program's channel,
part of the program protocol's frame profile in the ABI file
([design-programs.md](design-programs.md#the-program-protocol)). A
**notice** is a frame from a program that its handler takes without an
answer, and a **report** a frame from the handler that the program takes
without an answer; both travel on the channel in order and without loss:

| Message | Kind | Meaning | Answer |
| --- | --- | --- | --- |
| `{pipe, [cloexec \| nonblock]}` | request | make a pipe | `{ok, ReadDescriptor, WriteDescriptor}`; `{error, enfile \| emfile \| enomem}` |
| `{closed, Pipe, End}` | notice | the program's last reference to its end `End` went: its mappings and capabilities are closed; due once for each end a frame to the program named, a repeat ending the program with `SIGSYS` ([design-programs.md](design-programs.md#the-program-protocol)) | none |
| `{drained, Pipe, End, Writer}` | notice | the read end `End` drained the lane of write end `Writer`, which is gone, and unmapped and closed it; due once for each frame to the program that names `Writer` gone to `End`, a repeat ending the program with `SIGSYS` | none |
| `{deposit, Descriptor, Stream}` | request | the second tier's `SCM_RIGHTS`: hold an end for the end of a `{pipe, End}` descriptor, one for each end of a `{socketpair, ReadEnd, WriteEnd}` descriptor, or the open of a file, terminal or directory descriptor, for whichever read end of `Stream`, a write end the requester holds, meets the ticket ([Deposits](#deposits)) | `{ok, Ticket}`; or `{error, ebadf \| emfile \| enomem \| etoomanyrefs}`, `etoomanyrefs` when 16 deposits made through `Stream` are open |
| `{withdraw, Stream, Ticket}` | request | a `sendmsg` could not publish a ticket it was given; `Stream` is the write end the deposit was made through | `ok`, also for a deposit already closed |
| `{redeem, Stream, Ticket}` | request | take a deposit; `Stream` is a read end the requester holds | `{ok, Descriptor}`; `{error, ebadf}` for a ticket unknown, redeemed or of another pipe; `{error, emfile \| enomem}` when the install fails |
| `{discard, Stream, Ticket}` | request | a `read`, or a `recvmsg` without room for descriptors, skipped a deposit; `Stream` is a read end the requester holds | `ok`, also for a deposit already closed |
| `{pipe_writer, Pipe, End, Writer, Ring, RPage, Size, Doorbell, State}` | report | a write end joined the pipe of read end `End`: `Ring`, `RPage` and `Doorbell`, the trigger right, are values in the program's table, and the read end raises its count of write ends to `Writer` ([The lock page](#the-lock-page)). `State` is `open`, and the read end rings `Doorbell` once as it applies the report ([Waiting and doorbells](#waiting-and-doorbells)); or `gone`, when the handler owed the join and merged the writer's gone into it ([design-programs.md](design-programs.md#the-channel)), and the read end takes the lane as gone, drains it and lets it go | none |
| `{pipe_writer_gone, Pipe, End, Writer}` | report | the write end `Writer` of the pipe of end `End` is gone; a read end drains its lane and then lets it go | none |
| `{pipe_reader, Pipe, End, Rix, Doorbell, State}` | report | a read end at index `Rix` joined the pipe of end `End`: `Doorbell`, its trigger right, is a value in the program's table. `State` is `open`, and the end rings `Doorbell` once as it applies the report; or `gone`, when the handler merged the read end's gone into its owed join, and the end closes its copy of `Doorbell` at once and counts no read end for it | none |
| `{pipe_reader_gone, Pipe, End, Rix}` | report | the read end at index `Rix` of the pipe of end `End` is gone; a write end lowers its count of read ends, and every holder closes its copy of the doorbell | none |
| `{pipe_lost, Pipe, End}` | report | an install the end needed failed: the end counts as lost, its reads failing with `EIO` and its writes with `EPIPE` from then on ([Failure handling](#failure-handling-diagnostics-and-debuggability)) | none |
| `{pipe_server_lost}` | report | the session's pipe server ended: every pipe end the program holds is lost, and `liberx` wakes every worker waiting on one ([The pipe server](#the-pipe-server)) | none |

A spawn's or a fork's descriptors name a pipe end to inherit as
`{pipe, End}` and a socketpair as `{socketpair, ReadEnd, WriteEnd}`, and
the startup message names each pipe and socketpair descriptor of the
program:

```erlang
%% Descriptor = {pipe, write, PipeEnd, W}
%%            | {pipe, read, PipeEnd, R}
%%            | {socketpair, PipeEnd, R, PipeEnd, W}  % read end, then write
%%            | ...
%% PipeEnd = {Pipe :: pos_integer(), End :: pos_integer()}
%% W = #{wend := pos_integer(), ring := Cap, rpage := Cap,
%%       size := 16384 | 65536,
%%       readers := [{Rix :: 0..63, Doorbell :: Cap}]}        % at most 64
%% R = #{rix := 0..63, lock := Cap,
%%       wends := pos_integer(),        % the pipe's wends at the install
%%       writers := [{Wend :: pos_integer(), Ring :: Cap, RPage :: Cap,
%%                    Size :: 16384 | 65536, Doorbell :: Cap,
%%                    open | gone}],
%%       readers := [{Rix :: 0..63, Doorbell :: Cap}]}        % at most 63
%% Cap = a capability value in the program's own table
```

The decoders reject a value named twice, an index or a write end number
out of range or named twice, a size other than the two, and a list longer
than its bound: a write end's descriptor holds at most 2 + 64 = 66
capabilities, a read end's at most 1 + 63 + 3 w for a pipe with w write
ends, and the whole startup message at most its profile's bound, which
bounds w ([design-programs.md](design-programs.md#the-startup-message)).
They are generated from the frame profile, in `liberx` and in the handler,
and each has a fuzz target.

An end's `O_NONBLOCK` stays with the program that set it: an inherited
end never carries it, since it is another end, and an `exec` keeps it, as
POSIX keeps an open file description's status flags, through the handover
of the new image's startup message, which names every kept descriptor
whose object has it
([design-programs.md](design-programs.md#the-startup-message)).

### The session

The design relies on four contracts of the session's port driver and
handlers, which [design-programs.md](design-programs.md#the-handler)
defines:

* **Installs.** A program's handler installs capabilities of the session's
  table into its program's table, into a program being built before it
  runs and into a running one before the reply or report that names the
  values, through the session's own capability to that image's space,
  which names one image; a failed install into a running program fails
  the request or loses that end alone, and nothing is ever installed into
  an image that has gone, since the session's capability to a stopped
  space refuses it (`ERX_EDEAD`).
* **Ends of programs.** A program's handler sees the end record of each of
  its program's spaces at the session's fault gate and tells the pipe
  server every end the program held is gone, so no close is ever missed,
  whatever ended the program.
* **Order.** A program's channel delivers the handler's reports in the
  order sent and the program's requests and notices in the order sent,
  and nothing on it is lost or repeated, so the pipe server's records and
  each holder's view of its pipes agree without numbering or
  reconciliation.
* **Credit.** The port driver passes a program's requests and notices on
  only within the program's credit: one request per reply slot, one
  `{closed}` per end the program was given and one `{drained}` per writer
  named gone to it; a frame beyond it ends the program with `SIGSYS`
  ([design-programs.md](design-programs.md#the-program-protocol)). So
  the pipe server holds at most one message of a program per credit.

### The kernel

* **IRQ objects as doorbells.** Their creator, the only holder of the bind
  right, since no pass carries it, binds one to a thread or a scheduling
  group with a label; any number of holders of the trigger right ring it;
  a trigger that comes before the holder waits is kept, and triggers that
  come meanwhile count once; a ring of a deleted one fails with
  `ERX_ESTALE` ([design-kernel.md](design-kernel.md#irq-objects)).
* **Memory objects.** A copy with a rights mask is a slot of its own, a
  mapping keeps its object until it is unmapped, and only a holder of
  `DESTROY` can delete an object, after which every access to a mapping
  of it faults; the pipe server holds the only `DESTROY` and never uses it
  on a pipe's memory
  ([design-kernel.md](design-kernel.md#closing-and-deleting)).
* **Installs into a sub-space.** A space's creator alone installs
  capabilities into it, with `erx_cap_pass`, and a capability installed
  that way carries no `DUP` or `GIVE` unless the creator's mask keeps them
  ([design-kernel.md](design-kernel.md#passing-capabilities), K17).
* **The time page** gives a monotonic clock in nanoseconds, readable in
  user mode without a kernel call and consistent across CPUs
  ([design-kernel.md](design-kernel.md#port-contract)); the kernel's
  entropy generator gives the tickets.

### The ABI file

`abi/erx_abi.txt` holds, beside the lane's own layouts `erx_lane_hdr`,
`erx_lane_rpage` and `erx_lane_rec`
([design-domains.md](design-domains.md#lanes-and-frames-in-the-abi)),
the pipe's layouts `erx_pipe_rpage` and `erx_pipe_lock`, the record kinds
`ERX_REC_DATA` and `ERX_REC_CONTROL`, the limits
`ERX_PIPE_BUF` (4,096) and `ERX_PIPE_READERS_MAX` (64), `ERX_PIPE_NONE`,
the two ring sizes `ERX_PIPE_RING_FIRST` (65,536) and `ERX_PIPE_RING_NEXT`
(16,384), and the frame profiles of the messages above
([design-kernel.md](design-kernel.md#the-abi-file)).

## Compatibility and migration

Pipes keep the POSIX behaviour programs see; what differs is where they
live. Nothing of a pipe persists across a boot, and its layouts and frames
belong to the ABI version, which `liberx` and the session's runtime share
by construction, so a change to any replaces the old form outright, with
no reader kept for an earlier one, and a party built for another ABI
version is refused ([design.md](design.md#compatibility)). Documented
differences, each pinned by a test:

* a pipe has at most 64 read ends, and a spawn or a fork that would make
  another fails with `EMFILE`, where UNIX has no such limit;
* a reader that ends inside a `read` loses the bytes it was taking;
* a reader whose job is stopped while it holds the reader lock, which it
  holds only for a copy or a redemption, holds up its co-readers until it
  continues, where Linux stops a reader only outside its pipe's lock;
* a read of a pipe whose session lost its pipe server fails with `EIO`;
* `F_SETPIPE_SZ` and the other non-goals fail with `EINVAL`;
* a pipe end inherited by or passed to another program arrives as an end
  of its own, with a ring of 16 KiB where the pipe's first write end has
  64 KiB, which a program can tell only by the room a write finds.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | State left | Cleanup | What the user sees |
| --- | --- | --- | --- | --- |
| A ring's fields or records fail the reader's checks | the reader | the lane marked broken in that reader | none: the lane counts as gone and drained | one escaped line in the debug log naming the pipe and the write end; the stream goes on without that writer |
| A lane's `rpos` fails the writer's check | the writer | none | none | the writer waits as for a full pipe, or gets `EAGAIN`; `EPIPE` once no read end remains |
| A writer ends in the middle of a record | the end record of its space, at the session's fault gate | an unpublished record | the pipe server marks the write end gone and tells the readers | the readers read what was published, then the end of the stream |
| A reader ends holding the reader lock | the end record of its space | the lock held, a record partly claimed | the pipe server frees the lock with one compare-and-swap and tells the other read ends, whose waiters wake; the next reader continues the claimed record from `cur_off` or retires it | its co-readers go on; the bytes it was taking are lost, and none is read twice |
| A sender fails, is killed or lies between a deposit and its publication | `sendmsg`'s failure, or the drained reports of the sender's lane | a deposit whose ticket is in no lane | `{withdraw}`, or the drained reports, close it ([Deposits](#deposits)) | nothing: what the deposit held closes, and a pipe it kept open reaches its end of stream |
| `pipe`, or a read end beyond 64, the quota or a table | the pipe server's plan or an install | nothing: the objects made close | the steps before it undone | `EMFILE`, `ENFILE` or `ENOMEM` from `pipe` or the spawn |
| The pipe server crashes | its supervisor, and every handler's monitor | its capabilities closed by the destructors; its memory alive while parties map it | supervisor restart; each handler sends `{pipe_server_lost}`, and its program wakes its own waiters; each pipe's memory returns as its parties close their ends | reads fail with `EIO`, writes with `EPIPE`; later pipes work |
| An install into a running holder fails, because the holder's table or budget is full | the install's status | the end without the lane or the doorbell it needed | the pipe server closes the copy whose install failed and reports the end lost to that holder with `{pipe_lost, Pipe, End}`, after which the end counts as lost, its reads failing with `EIO` and its writes with `EPIPE`, as [Writing](#writing) says of a lost pipe | a program that exhausts its own table or budget with its own objects loses only its own end; within the `pipes` quota, pipe installs alone never exhaust it ([Inherited ends](#inherited-ends)) |
| A program floods its handler with pipe requests or notices | the port driver, which passes on a program's frames only within its credit: 16 requests, one `{closed}` per end and one `{drained}` per writer named gone to it | none | a request on a busy slot or a notice that is not due, a repeat included, ends the program with `SIGSYS`, as a malformed record does ([design-programs.md](design-programs.md#the-program-protocol)); within its credit, the program waits for room in its own lane | the program's parent sees `SIGSYS`; the handler and the pipe server hold at most one message per credit of it, and its siblings are served |

Every pipe and end appears in `/proc` and the inspector: the pipe server
reports each pipe's ends, their holders and states, and each lane's size
and the bytes it holds as read from its header, marked as reported by the
ring rather than verified
([design-live.md](design-live.md#inspection)). A program's descriptor
listing names each end's pipe and end numbers, so a hung pipeline shows
which writer still holds a pipe open.

## Security

**Trust boundaries.** Each holder of a page can write every byte of the
pages it maps writable, so every field a party reads from a page another
party writes is untrusted input to it:

| Input | From | Validation |
| --- | --- | --- |
| a ring's `wpos` and records | its writer, the only party with a writable mapping of it | copied once into private memory; `erx_ring_check` with checked arithmetic; a violation marks the lane broken |
| a lane's reader page | the read ends | copied once; the writer's check of `rpos`; a violation counts as a full ring; `wake` and `sleepers` are only compared and tested, so a false value costs a needless ring or delays the co-readers of the stream, and never makes the writer fail |
| the lock page | the read ends | each field checked against the reader's own records |
| pipe requests and notices | programs, through the program protocol on their channel | the generated decoders and their bounds; the pipe server acts only on an end the channel's program holds |
| a control record's tickets | any writer of the stream | a ticket is 64 random bits the pipe server issued for a deposit on that pipe and redeems once; any other value is refused, and a record's kind is in its writer's own ring, so data never reads as tickets |
| reports from the handler | the session | trusted: a program takes them only from its channel, which the session alone writes |

**Isolation.** A writer writes only its own ring, so a hostile writer can
corrupt only its own records, delay the end of the stream by keeping its
end, or stamp its records early, which puts its records ahead of another
writer's record by at most two lanes' capacity for each read end ([Reading
and merging](#reading-and-merging)). A hostile reader can corrupt the lock
page and the reader pages, steal or garble the stream for its co-readers,
hold the reader lock, or stop the stream's writers by a false read
position, all within the stream it already shares, as a UNIX reader that
reads everything or stops reading can; it cannot write a writer's records,
since it maps every ring read-only, and it cannot make a writer fail,
since nothing a reader writes decides `EPIPE`.

**Limits.** A session holds at most its `pipes` quota of lanes, set by
`erx_policy` like its other quotas
([design-system.md](design-system.md#resource-policy)); a pipe at most 64
read ends, and each write end at most 16 deposits; every object is charged
to the session's budget, never to a program's, whose destruction at its
end would delete it under the other holders. A program's budget is sized
for the quota, three
capabilities and one lane's mappings for each lane it allows, so the
capabilities a reader holds for lanes it has not drained never fill it
([Inherited ends](#inherited-ends)). What a program's frames make the
handler and the pipe server hold is bounded by its credit, one message for
each reply slot, each end it was given and each writer named gone to it
([design-programs.md](design-programs.md#the-program-protocol)). Every
check and loop is bounded by those limits and by the party's own records,
never by a value read from shared memory.

**Leaks.** A ring holds only bytes written into the pipe, and memory
objects are zero when made. A pipe's memory is never deleted under a
party that maps it, so no party reads memory that is gone, and none
faults. Bytes from a pipe reach a terminal only when a reader writes them
to a tty, which delivers them unchanged, as on UNIX
([design-live.md](design-live.md#the-tty)).

**Residual risks accepted.** Co-readers trust each other with their shared
stream; a holder that keeps an end delays the end of the stream or a
broken pipe for everyone else, as on UNIX; a writer can ring its readers'
doorbells needlessly, which costs each at most one wake per wait; a reader
that keeps a gone writer's lane mapped and never drains it holds that lane's
memory, charged to the session, until it ends; a reader whose job is
stopped inside the reader lock holds up its co-readers until it continues;
and the timing channel through memory shared between a writer and its
readers, which any pipe has.

## Verification and testing

* **Pure cores on the host.** `erx_ring_check`, `erx_pipe_wstep`,
  `erx_pipe_rstep` and `erx_pipe:step/2`, explored as
  [The pipe core](#the-pipe-core) describes, under ASan and UBSan, with
  properties: no byte lost, duplicated or reordered within a writer; every
  record of at most `PIPE_BUF` bytes read contiguously; writes that
  happened one after the other read in that order; the end of the stream
  and `EPIPE` exactly when PI2 and PI3 say; no wakeup lost; no field read
  twice from shared memory, checked by an instrumented accessor. Each
  property has a seeded failure: a model with one fence removed, a reader
  that advances `rpos` before its copy, a writer that publishes before its
  payload is written, and a pipe server that forgets to tell one reader of
  a gone writer, each of which the exploration must catch.
* **Fuzz targets.** The consumer's check over arbitrary header and record
  bytes and positions; the producer's check over arbitrary `rpos`; the
  lock page's checks; the decoders of the pipe requests, notices, reports
  and descriptors, in `liberx` and in the handler (`make check-fuzz`).
* **Domain tests**, each a QEMU test: `echo hi | cat`, whose writer ends
  before the reader reads; two writers in two programs, with the end of
  the stream only after both end; a writer that faults mid-record; a
  reader that faults while its writer waits for room, whose writer gets
  `EPIPE` and `SIGPIPE` at once; `yes | head -1`; a hostile writer that
  rewrites its header and records at random while a second writer's stream
  arrives intact; a reader that tries to write a ring and faults; a writer
  that stamps every record 0 and never lets its ring empty, while another
  writer's records arrive within the service bound; a co-reader that
  rewrites a lane's read position, which stops the writer without
  `SIGPIPE`; `(cat f1; cat f2) | (head -1; cat)`, which prints every line
  once, in order; `{date; uname} | cat`, in that order every time; 100
  writers writing 4,096-byte lines, each arriving whole; 100 writers
  started one after another under a reader that reads only after 10 s,
  every line arriving; `make 2>&1 | less` with the pager paused, whose
  64th and 200th children spawn and whose writes wait for room, and every
  install into the pager succeeds up to the `pipes` quota; a 65th
  read end, which fails with `EMFILE`; 10,000 sequential inherited write
  ends under one reader, whose lanes are let go as they drain and whose
  memory returns; `poll` over 500 pipe ends, reporting exactly the ready
  ones; `close` of an end another thread reads; each `O_NONBLOCK` case of
  PR1; a program that tries to copy an end's capabilities and to pass them
  at a rendezvous; a program at the session's `pipes` quota; `SCM_RIGHTS`
  of a pipe end, which the sender keeps; a socketpair's end sent over
  itself and closed, after which both peers see the end of the stream; a
  `read` that skips a control record, whose deposit closes; a write whose
  bytes look like a ticket, which reads as data; two writers of one
  stream, one preempted between stamping its control record and its first
  data record while the other writes, whose descriptors arrive with their
  own bytes; a writer that fills its ring before its reader first waits,
  and a reader that waits before its writer's first write, each of which
  wakes; a `pipe` followed by a `fork` whose child inherits both ends, and
  a pipeline of three forked stages sharing one pipe, each of which
  completes; an `exec` of a reader while a sibling forks a writer of its
  pipe, whose new image reads that writer's records (P11 of
  [design-programs.md](design-programs.md#invariants)); an `exec` of a
  reader with a gone writer's lane half read, whose new image reads the
  rest; a writer that joins a pipe while a forked child that holds a read
  end of it is built but not yet started, whose lane the child holds when
  it starts; an install into a holder whose table is full, which reports
  the end lost to that holder alone; and a crash of the pipe server, after
  which blocked readers and writers wake with `EIO` and `EPIPE`. The
  exploration of `erx_pipe:step/2` checks, over every order of inherit,
  closed, gone, drained, exec, deposit, redeem, discard and withdraw
  events, that every recorded holder, a redeemer included, holds every
  lane and doorbell its end needs from the moment it can run.
* **Deposits, the reader lock and doorbells**, each a QEMU test: a reader
  that ends holding the reader lock while three co-readers wait, all of
  which go on; a reader that ends after claiming a record's last bytes,
  whose record no co-reader reads again; a `sendmsg` under `O_NONBLOCK`
  into a full ring, which fails with `EAGAIN` before it deposits anything;
  a `sendmsg` of two descriptors whose second deposit fails, whose first
  is withdrawn, so the pipe whose write end it deposited reaches its end
  of stream once the sender closes its own; a read end redeemed after a
  writer joined its pipe, which reads that writer's bytes; a write end
  redeemed after a reader began to wait, which wakes that reader; a writer
  that deposits 16 times without publishing, whose next deposit fails with
  `ETOOMANYREFS` while a co-writer's `sendmsg` passes a descriptor; a
  signal, and `alarm` with `siglongjmp`, during a redemption, whose
  handler runs once the redemption ends, after which the reader lock is
  free and the co-readers read on; a sender killed between its deposit and
  its publication, whose deposit closes when its lane drains; a file
  queued on stream P whose read end is then sent over stream Q and closed,
  which Q's reader redeems before it receives the file through P;
  `tail -f log | while read l; do cmd; done`, where each `cmd` that reads
  standard input takes a read index in turn and is woken by `tail`; a pipe
  whose ends one program holds, which installs nothing beyond the
  program's own; a write end kept across `exec` and then closed, whose
  readers' later rings of its doorbell wake none of that program's
  waiters; a reader stopped inside the reader lock by a test hook, whose
  co-reader in another job waits until it continues; and a crash of the
  pipe server while a program waits on a pipe whose ends it alone holds,
  which wakes with `EIO`.
* **Oracle.** The same scripted single-reader workloads run against the
  development host's pipes, and the byte streams, counts and error codes
  are compared; the Open POSIX Test Suite's pipe cases run with the
  personality's other suites
  ([design-programs.md](design-programs.md#verification-and-testing)).

## Performance

**Cost model.** A write of `n` bytes, at most `PIPE_BUF`, while no reader
sleeps costs a clock read, a copy of `n + 16` bytes rounded up to 16, two
copies of shared fields and a store around a full fence, with no kernel
call; when a reader sleeps it adds one trigger of each sleeping read end's
doorbell. A read costs the reader lock, a clock read and a copy of each
lane's write position and first record header, one cache line per open
write end, a copy of the payload, and a trigger when the writer waits. A
pipe in the kernel would cost two kernel calls per transfer and a copy
into and out of a kernel buffer on each side.

**Budgets**, each a target that `tools/erx bench pipe` checks, none a
measurement:

* A small write or read without a doorbell: under 200 ns plus the copy at
  memory bandwidth, from two fences and a handful of cache-line transfers
  between two CPUs.
* A doorbell: one kernel call, an estimated 1 to 2 us under HVF, at most
  once per batch, since a writer rings only when its store crosses the
  position a waiting reader published.
* A pick across `w` open lanes: `w` header lines, an estimated 1 to 3 us
  for 64 of them; a pipe with hundreds of open write ends pays in
  proportion at each read, which is the price of unbounded writers.
* Bulk throughput of one writer and one reader with a 64 KiB ring: limited
  by copying, an estimated 2 to 5 GB/s between two CPUs under HVF.
* Memory: a pipe with one end of each kind, 76 KiB of memory objects (the
  lane's 68 KiB ring object and 4 KiB reader page, and the 4 KiB lock
  page) and two IRQ objects, plus translation tables in two spaces; each
  further write end 24 KiB and an IRQ object; each further read end an IRQ
  object.
* `pipe` from a program: a frame to its handler, four object creations,
  two bindings and the installs, an estimated 20 to 50 us from kernel calls
  of 1 to 2 us and the handler's Erlang steps, with no third party.
* An inherited end, or an end the session makes for a pipeline stage: a
  lane or an index, a doorbell, one install into each peer with its
  report, and the child's copies among its creation, an estimated 10 to
  30 us in all, against the budget of 1 ms for a program's start
  ([design-programs.md](design-programs.md#performance)).

**Benchmark.** `tools/erx bench pipe` measures one writer and one reader
moving 1 GiB with writes of 4 KiB and 64 KiB, 64 and 256 writers of
100-byte records under one reader, the latency of one byte through an idle
pipe, `pipe` and spawns with inherited pipes per second, and `poll` over
500 ends, under HVF on the development host, each result with its host,
accelerator, QEMU version, compiler, flags, workload and baseline; TCG
numbers are never compared with HVF numbers. The budgets above are
refuted if a single small write costs more than 1 us without a doorbell or
bulk throughput falls below 1 GB/s.

## Portability

The rings use C17 atomics and fences, 32-bit compare-and-swap on the
reader lock, 64-bit atomic or and and on the wait masks, and the time
page's clock; nothing depends on an architecture or a board. In hosted
mode, `liberx`'s hosted backend provides memory objects and doorbells
inside a macOS process
([design-runtime.md](design-runtime.md#hosted-mode)), and the pipe core's
model runs on every host.

## Dependencies

No dependencies of their own: pipes use `liberx`, the session's runtime
and kernel objects that exist for other purposes.

## Alternatives considered

**A kernel pipe object.** The kernel would own the buffer and count each
end's holders, as UNIX kernels and Zircon's sockets do. The user chose to
keep pipes out of the kernel; a kernel buffer also costs two kernel calls
and bounce copies per transfer, which shared rings avoid.

**One shared ring per pipe with a writer lock.** All writers would append
to one ring under a lock in shared memory. It loses: writers in different
spaces would share memory, so a hostile writer could overwrite the bytes
of others before they are read, and a writer that ends holding the lock
would stop the pipe.

**A token per end, watched by the session.** Each end's identity would be
a kernel object that can only be moved, with a release signal that tells
the session when it goes, so that end of stream follows from the kernel's
count of holders. It loses to the session's own records: the session
alone installs every end, so it knows every holder already; a holder's
close reaches it as a notice and a holder's death as the end record of
its space, which its handler sees whatever ended it; a token would add a
kernel type, a watch per end and a move per inheritance for a fact the
session has by construction, and the kernel would still not tell the
session which holder's end went without a label per end.

**A status page the session writes.** Each pipe would have a page, mapped
read-only by every end, in which the session publishes which write ends
are open and whether a read end remains. It loses: the channel already
carries the same facts to each holder, in order and without loss, and a
page needs a fixed table of write ends, which bounds them and makes a
spawn fail when the table is full, where UNIX blocks a writer and never a
spawn.

**Rings held by the reader, a registration gate and lending.** The read end
would create and keep the rings; a writer would register at a rendezvous
on the read end's IPC gate; and a program starting a command that
inherits its standard input would lend it the read end, which came back
when the command ends. It loses on correctness: a writer registered while
the read end is lent leaves its ring in the borrower's table, so when the
borrower ends the ring goes and its writer gets `SIGPIPE` though the read
end lives on, which breaks `(cat f1; cat f2) | (head -1; cat)`; and a read
end cannot be shared at all, so concurrent readers are impossible. With
the session as the home, no gate, service thread or lending is needed, and
both cases behave as on UNIX.

**End of stream and broken pipe from fields in the rings.** A reader could
learn that its writers are gone, and a writer that its readers are, from a
flag in a shared page. It loses: whoever can write the page could make a
writer fail with `EPIPE` while readers remain, or hide its own end. The
session's reports, which only the session sends, carry both.

**A umtx word as the reader lock.** Read ends would wait for the lock on
a umtx word in the lock page. It loses: `poll` and the session's pipe NIF
wait only for doorbells, so a lock released while they wait would wake
neither; with a waiting bit and a doorbell, every wait of a pipe is the
same wait.

**Doorbells made by each holder.** Each end's holder would create its own
doorbell, bind it where it waits, and hand the session the right to ring
it, which the session would copy to the peers. It loses: the session must
then collect the doorbell from the holder's table, check who bound it, and
copy it on, and until it has, a peer whose store crosses the position
the holder published has nothing to ring; the session creates and binds
every doorbell before the end's holder can run, since it holds the right
to bind on every group it created, so no gap exists.

**Flags cleared by the ringer.** A waiter would set a flag and the party
that rings it would clear it by an exchange, so that no needless ring
follows. It loses, as it does for every lane
([design-domains.md](design-domains.md#alternatives-considered)): the
ringer would then write a page the waiter owns, so a writer would map its
readers' page writable and a reader its writer's header; with a published
position that the ringer only compares, each party writes only its own
page, a lane's two pages are mapped read-only by the other side, and a
position already crossed is never rung again.

**A slot's ring kept for the next writer.** A gone writer's ring could pass
to the next write end, saving a lane. It loses: the gone writer would keep
its copy and could write into the next writer's ring, and a hostile gone
writer's last records would sit in front of the next writer's, so readers
would need a boundary between writers that they cannot get from the ring
itself.

**A pipe server that carries the bytes.** As QNX's pipe manager does, a
server would receive every write and answer every read. It loses: every
byte would pass through a third party, with two extra copies and a round
trip per transfer, where shared rings need no third party on the data path.

**Pipes as frames on the channel.** A pipe would be a protocol of data and
credit messages through each program's handler. Rejected in
[design-programs.md](design-programs.md#alternatives-considered): every
byte would cross the session, and the end of the stream would rest on
every reader tracking every writer.

**Pipes that survive the pipe server's crash.** The pipe NIF's resources
could have an owner that outlives the pipe server, such as an ETS table's
heir, so a restarted pipe server would find its pipes again. It is not
adopted: events that arrived while no pipe server ran, closes and drained
reports among them, would have to be rebuilt from the holders before any
pipe could be trusted again, a reconciliation with failure cases of its
own, while a lost pipe fails loudly with `EIO` and `EPIPE`. Pipe-server
crashes seen in practice would reopen it.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| A lost wakeup between a published position and its fence | low | a pipe stalls until the next change | PI7; the exploration over the memory model's orders; the stress test |
| A program that keeps a gone writer's lane mapped holds memory the session pays for | low | the session's budget shrinks by up to one lane per such writer until the program ends | lanes are 24 KiB or 72 KiB, a program's end returns them, and the `pipes` quota counts the lanes the pipe server makes; a domain test that keeps a gone writer's lane and checks the memory returns when the program ends |
| A pipe with hundreds of open write ends makes every read scan hundreds of header lines | medium | a `make -j` with many parallel children under one reader reads slowly | the scan is one cache line per open lane and gone lanes are let go as they drain; `tools/erx bench pipe` with 256 writers; if it matters, the reader keeps a ready set from a per-lane "has data" flag the writer sets at publication, in the ring header it already writes |
| The limit of 64 read ends is too low for some program | low | a spawn or a fork fails with `EMFILE` at a 65th read end | the limit is an ABI constant from the width of the wait masks; raising it costs a wider mask in the reader page and the lock page |
| Lanes cost more memory than a kernel pipe | medium | sessions with many pipelines use more of their budget | 16 KiB rings for inherited ends; the `pipes` quota; the measurement of a program's cost ([design-programs.md](design-programs.md#performance)) |
| The monotonic clock disagrees between CPUs | low | records of two writers arrive slightly out of order | the port contract requires a clock consistent across CPUs ([design-kernel.md](design-kernel.md#port-contract)) |

No open question remains for the user. One engineering question, with the
answer the design follows:

* **Are 64 KiB and 16 KiB the right ring sizes?** Recommended: keep them,
  matching Linux's default for a pipe's first writer and FreeBSD's for the
  rest; `tools/erx bench pipe` and the measured cost of a program settle
  whether inherited ends' rings should be smaller or the first ring larger.

## References

* The Open Group Base Specifications Issue 8 (IEEE Std 1003.1-2024): `pipe`,
  `read` ("If no process has the pipe open for writing, read() shall
  return 0 to indicate end-of-file"), `write` ("Write requests of
  {PIPE_BUF} bytes or less shall not be interleaved with data from other
  threads", the `O_NONBLOCK` rules and `EPIPE` with `SIGPIPE`), `poll`
  (`POLLHUP` and `POLLERR`), https://pubs.opengroup.org/onlinepubs/9799919799/
  (read 2026-10-31).
* Linux man-pages 6.19, pipe(7) (2026-07-10), "Pipe capacity" (65,536
  bytes by default) and "PIPE_BUF" (4,096 bytes on Linux),
  https://man7.org/linux/man-pages/man7/pipe.7.html.
* Linux 6.17, `fs/pipe.c`: `anon_pipe_read` takes the pipe's mutex before
  it looks at `O_NONBLOCK`; `pipe_poll` reports `EPOLLHUP` without
  `EPOLLIN` once no writer remains and the pipe is empty, and `EPOLLERR` on
  a write end without readers,
  https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/fs/pipe.c?h=v6.17
  (read 2026-10-31, SHA-256
  `6d6d680a3109980cba6f34fe8710173dbf18e7c4bf3780c2000cc742bd91e5a6`).
* FreeBSD, `sys/sys/pipe.h`: `PIPE_SIZE` 16384, `BIG_PIPE_SIZE` 65536,
  https://github.com/freebsd/freebsd-src/blob/main/sys/sys/pipe.h (main,
  read 2026-10-31).
* The seL4 Device Driver Framework 0.7.0 (`650ace5`): single-producer,
  single-consumer rings with a signal for each side between drivers,
  virtualisers and clients, https://github.com/au-ts/sddf, as surveyed in
  [research-kernel-bases.md](research-kernel-bases.md#sddf).
