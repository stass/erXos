# The CBMC pilot

A point-in-time record of the Track K pilot's CBMC harnesses on the
pilot's finished cores, written 2026-11-08 for the owner's decision on
adopting CBMC (decision Q19 of the pilot's charter: adoption is decided
from this record). The harnesses, the roster and the runner are described
in [design-verification.md](design-verification.md#cbmc-harnesses-and-runner);
this record gives what they cost, what they caught and what they add to
the host tests and fuzz targets that check the same cores.

## Setup

| | |
|---|---|
| Date | 2026-11-08; the gate run's report is dated 2026-11-08T13:36:26Z |
| Host | Apple M3 Max, 16 cores, 128 GiB, macOS 27.0.1 |
| cbmc | 6.11.0 from Homebrew, `/opt/homebrew/Cellar/cbmc/6.11.0/bin/cbmc`, SHA-256 `216a8a11add362e5eaf191bbc3d3b4e2d72f1ef1461d9e00bff483c61aa049ad` |
| Solver | CaDiCaL as built into cbmc 6.11.0 (`--sat-solver cadical`); cbmc does not report the solver's version |
| Preprocessor | cbmc's default on macOS, `/usr/bin/gcc`, which is Apple clang 21.0.0 (clang-2100.3.34.2) |
| Checks | `--bounds-check --pointer-check --pointer-overflow-check --signed-overflow-check --unsigned-overflow-check --conversion-check --undefined-shift-check --div-by-zero-check`, with unwinding assertions |
| Tree | branch `trackk-p7b` of erXos, on the pilot's cores at `trackk-p4c` (`f9e61c4d`) |
| Sources | `/Users/stas/erxos-history/track-k-pilot/cbmc/`: the gate run's `cbmc-final-report.json` and `.txt`, the rerun of P7a's harnesses before any change (`cbmc-baseline-report.json`), peak memory under `/usr/bin/time -l` with the roster's command lines (`memory.txt`), and the larger-bound runs (`measure-page.out`, `measure-cap_slot_list.out`), at erxos-history commit `df0c29e` |

The gate runs one harness at a time, each cbmc process single-threaded.
Wall times are the gate's own; peak memory is the maximum resident set
size of a separate run of the same command line.

## Harnesses

Nine harnesses: six from P7a, which verified on the finished cores
without edits to their sources (they now also pick up the two shared
headers changed below), and three added here. The roster (`test/cbmc/roster.json`) keeps each
one's bounds, assumptions and unchecked constructs; the summary:

| Harness | Core | Bounds | Main assumptions and gaps |
|---|---|---|---|
| budget_arith | budget.c | every 64-bit input; no loop | none |
| budget_step | budget.c | every budget record, change and dead rule at full width | lock effects are stubs |
| budget_chain | budget.c | chains of 3 budgets, counters at most 255, any 64-bit change | depth 3 of the 16 allowed; one thread |
| cap_slot_close | cap.c | every resting count and generation, up to two opening writes | atomics sequentially consistent |
| cap_read | cap.c | tables of 2 to 128 slots, one slot in any quiescent state, every value | only the quiescent read; the retry under a writer is unchecked |
| cap_rights | cap.c | every pass request of up to 4 items | sources free |
| grace_tracker | grace.c | any invariant state at full width over 64 CPUs, one retirement and 4 more calls | a stamp's life over 4 calls; no liveness |
| page_funnel | page.c | 4 pages, 5 calls (charge, backing step, take, release, free, end of grace periods) | grace tracker, reserve steps and allocator are stubs of their contracts; one thread |
| cap_slot_list | cap.c | one page, two objects, 2 calls (install, copy, clear, close), then one lookup; values naming slots 0 to 3 at generation 0 or 1 | object store and attach insert are stubs; a clear of a slot with a neighbour on its list is never reached, so the unlink's neighbour branches are unchecked |

The runner checks one core per harness, so a harness over a protocol that
spans cores (the funnel over the tracker, the table over the object store)
stubs the other core by its header's contract and leaves that core to its
own harness or host model.

Two changes made the new harnesses possible, and apply to every harness:
`test/cbmc/cbmc_harness.h` turns each `__builtin_trap` a harness reaches
into a failing property (before, any core with a trap on the path was a
tool error, since cbmc has no body for it), and
`test/cbmc/include/stdatomic.h` maps `atomic_init`, exchange,
compare-and-exchange and fetch-and-add, which the object store and grace
tracker use.

## Cost per run

The gate run, one at a time on the host above:

| Harness | Properties | Wall time | Peak memory | Seeded defects | Their wall time |
|---|---|---|---|---|---|
| budget_arith | 1603 | 0.6 s | 37 MiB | 2 | 0.9 s |
| budget_step | 1620 | 4.8 s | 105 MiB | 1 | 3.2 s |
| budget_chain | 1818 | 37.1 s | 3.5 GiB | 3 | 91.5 s |
| cap_slot_close | 1496 | 0.3 s | 46 MiB | 1 | 0.3 s |
| cap_read | 1500 | 135.5 s | 9.5 GiB | 1 | 105.3 s |
| cap_rights | 1577 | 1.0 s | 152 MiB | 1 | 1.1 s |
| grace_tracker | 309 | 5.7 s | 146 MiB | 3 | 6.0 s |
| page_funnel | 729 | 338.7 s | 20.6 GiB | 4 | 1425.8 s |
| cap_slot_list | 1618 | 1272.0 s | 88.1 GiB | 4 | 5759.7 s |

The whole gate took about 2 hours 33 minutes: 1,796 s of harnesses and
7,394 s of seeded defects (9,190 s). Of that, page_funnel and cap_slot_list took
8,796 s, 96 percent; the other seven harnesses and their 12 defects took
about 393 s.

Larger bounds were measured during development. These runs differ from
the gate's in more than the number of calls: they used the real grace
tracker or object store where the gate's harnesses use stubs, they check
more properties, the 3-call slot list narrowed the capability values,
and a second cbmc ran on the host at the same time. They show the order
of cost, not the cost of one more call:

| Harness | Bound | Wall time | Peak memory |
|---|---|---|---|
| page_funnel (real grace tracker) | 6 calls | 1,256 s | 17.0 GiB |
| page_funnel, two of its defects | 6 calls | 1,550 s and 1,829 s | 28.5 GiB and 21.3 GiB |
| cap_slot_list (real object store) | 3 calls, narrowed values | 2,864 s | 86.9 GiB |
| cap_slot_list (real object store) | 4 calls, every value | stopped after 40 min | 67 GiB when stopped |

What separates the cheap harnesses from the dear ones is the state they
model, not the number of calls: grace_tracker makes five calls over a
record of a few words and takes 6 s, while page_funnel and cap_slot_list
model records linked by pointers (page chains, slot lists over a 64-slot
page) and take minutes to tens of minutes and up to tens of GiB at two
to five calls. The 4-call slot list over every capability value did not
finish.

## Seeded defects caught

Twenty seeded defects ran; 19 were caught by the property their roster
pattern names. The new ones:

* grace_tracker: a retirement that stamps the period in progress (caught
  by the stamp's maturity), a requested period that awaits no CPU (caught
  by the ghost set of owed CPUs), a retirement that restarts the period in
  progress (caught by the record invariant).
* page_funnel: the reaper freeing immature pages, a backing pooling its
  hand without waiting, a take that forgets the newest stamp (each caught
  by a maturity property), a splice that loses its count (caught by the
  counts).
* cap_slot_list: an install that leaves the old head's back link, a clear
  of the head that leaves the object's head on the cleared slot, a lookup
  that ignores the object's state and budget (each caught by the list or
  lookup properties).

The twentieth, a clear that does not uncount the slot on its object
(cap_slot_list), ran into its 1,800 s deadline without a verdict and was
removed from the roster. It needs two calls, an install and the clear, so
it is inside the bound: the solver did not reach it in 30 minutes. Since
the slot-list harness and its other defects took 1,262 s to 1,407 s, its
deadline is raised to 3,600 s so that load does not time them out. No
seeded defect now checks the slot-list harness's count property.

## Bugs found

CBMC found no bug in the pilot's cores, in P7a or here. Every property it
checks held on the cores as committed.

What it did find was in the harnesses and their scaffolding:
* a harness reaching a core's `__builtin_trap` was a tool error, not a
  checked property (fixed in `cbmc_harness.h`);
* the model header lacked `atomic_init`, which the grace harness uses to
  set up its record; cbmc warned of a function with no body, and the runner
  made the run a tool error, as it intends;
* the page funnel's first allocator stub handed out fewer pages than it
  had, which no real allocator does, and CBMC duly reached the funnel's
  trap for a broken identity.

None of these is a defect of the kernel's code.

## What the host tests and fuzz targets already check

The same cores have host models, exhaustive explorations and fuzz targets
(test/host, test/fixtures, tools/fuzz), which run in `make check` and
`make check-fuzz` in seconds to minutes:

* **Grace tracker.** `test/host/page_test.rb` runs random scripts of 60
  steps against a model and checks that a stamp matures only after every
  CPU online at its retirement reported or left; `tools/fuzz/page_fuzz.c`
  checks the same over any sequence, and that every stamp matures once
  every CPU has reported twice, which CBMC's harness does not check.
* **Page funnel.** `tools/fuzz/page_fuzz.c` runs any sequence of tracker
  and funnel calls over several reserves of a real budget root and checks
  everything page_funnel checks (a page pooled only once mature, each page
  in one place, stamps in order), and also that a release's pages are on
  the list before its refund takes the budget's lock, which a
  single-thread CBMC harness cannot see.
* **Slot lists and lookup.** `test/host/cap_test.rb` explores every state
  reachable from slots near generation and count exhaustion until the set
  of states closes, against an independent Ruby model;
  `tools/fuzz/cap_fuzz.c` checks after every operation that each object
  counts exactly the live slots naming it in both tables, each listed once
  through `obj_prev` and `obj_next`, and that a lookup returns only a LIVE
  object; `test/host/object_test.rb` builds the lookup against mutants
  that drop the state or the budget check.
* **Budget.** `test/host/budget_test.rb` runs every two-budget tree of 7
  shapes under each of 14 operations, and random trees, against a model; `tools/fuzz/budget_fuzz.c`
  derives every counter from a shadow and drives operands to the edges of
  the checked arithmetic.
* **Deletion.** `test/fixtures/delete_model.c` explores every interleaving
  of up to four actors over the real object store, attach, deletion and
  capability cores, with the real grace tracker.

So every property the three new harnesses check was already checked by a
fuzz target or a host model (the grace record's invariant by
`page_test.rb`'s model, the rest by the fuzz targets), and the stateful
ones by tests that reach deeper (60 random steps, any fuzzed sequence, or
a closed set of capability states) at a fraction of the cost. Where CBMC adds
something the others do not is width: budget_arith and budget_step cover
every 64-bit input of the arithmetic, cap_read every capability value
against every slot state, and grace_tracker every state the record
invariant allows at full width, each in seconds; fuzzers sample those
spaces and models use small values.

## Recommendation

**Adopt CBMC for loop-free or shallow arithmetic and single-decision
functions over full-width inputs; do not adopt it for protocols over
records linked by pointers.**

The argument from the numbers:
* The seven harnesses of the first kind (budget_arith, budget_step,
  budget_chain, cap_slot_close, cap_read, cap_rights, grace_tracker) caught
  all 12 of their seeded defects, and their whole run, harnesses and
  defects, took about 393 s; without cap_read and budget_chain, about
  24 s and at most 152 MiB of memory, against 9.5 GiB and 3.5 GiB for
  those two. Each covers
  an input space no fuzzer or small-value model covers. The cost per build
  is small enough to run in `make check-cbmc` on every change to those
  cores.
* The two harnesses over linked records (page_funnel, cap_slot_list)
  cost 8,796 s, 96 percent of the gate, with peak memory of 20.6 GiB and
  88.1 GiB (two thirds of the host's 128 GiB), for two to five calls of depth; one of their eight defects timed
  out, and the slot list's bound cannot reach a clear with a neighbour. Every property
  they check is already checked, deeper and faster, by the fuzz targets and
  host models. They found nothing those had not.
* CBMC found no kernel bug in the pilot. Its value so far is assurance
  over full-width inputs, not defects found.

Concretely: keep the seven harnesses in the per-change gate (about 6.5
minutes, or about 24 s for the five cheapest); move page_funnel and cap_slot_list
out of it, to an on-demand run or out of the roster, since the fuzz
targets own those properties. New harnesses should target pure decision
functions, arithmetic with overflow edges, and validators of untrusted
input, where full-width inputs over a small record are the point; a
harness that needs a chain or list of records is a sign the property
belongs to a host model or a fuzz target.

Adoption leaves three open items, recorded in `TODO.md`: pinning cbmc by
hash rather than by Homebrew's moving formula, recording the preprocessor
cbmc runs, and keeping cbmc's standard error out of the output the runner
parses.

The candidates the pilot named but did not cover (the retirement and
release path, the budget keep path of P4's review M4, and the deletion
core's steps) are protocols over linked records, so by the
numbers above they belong to host models and fuzz targets rather than
to CBMC. The deletion model already explores the deletion core's steps
and the release; whether the keep path has such a test is not checked
here.
