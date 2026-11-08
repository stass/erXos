# Track K pilot: timing

A point-in-time record of how long the Track K pilot's packages took,
written 2026-11-08 when its last package, P7b, was finished. The pilot
built the first host-only C17 cores of erXos's own kernel (object store,
capability table, attach, release and deletion, budget integration, the
grace tracker and page funnel, the chokepoints, and the CBMC pilot), and
was timed so that the rest of the kernel (GK1 onwards in
[plan.md](plan.md)) can be estimated from it.

**Source.** The timing log is
`/Users/stas/erxos-history/track-k-pilot/timing.csv`, one row per event
(brief sent, first commit done) with the agent's tool-call count, at
erxos-history commit `df0c29e`; this summary covers its rows up to P4c's, plus P7b's, which P7b
added with this record. The pilot's charter, in the same directory, fixes the scope
and starts the clock at 2026-11-07T23:09:57Z.

**Target.** The working rule is one narrow task per agent, ending in one
reviewed commit, sized to fit in roughly 50 to 100 tool calls.

## Calls per package

| Package | Work | Tool calls | Brief to first commit |
|---|---|---|---|
| PD | design reconciliation | ~118 | 24 min |
| P1 | object store | ~176 | 54 min |
| P7a | CBMC scaffolding | ~210 | 2 h 09 min |
| P2 | capability table | 208 (counted) | 2 h 08 min |
| P5 | grace tracker, page funnel | 244 (counted) | 2 h 33 min |
| P3 | attach, release and deletion | ~137 | not logged |
| P4 | budget integration, part 1 | ~150 | not logged |
| P4b | budget integration, part 2 | ~150 | not logged |
| P6 | chokepoints | ~135 | not logged |
| P4c | budget integration, part 3 | ~122 | not logged |
| P7b | CBMC final run and record | ~180 | not logged |

A count marked `~` is the agent's own; "counted" is the harness's count.
Where both exist they disagree by a quarter or more (P2: about 150
estimated, 208 counted; P5: about 190 estimated, 244 counted), so the
estimates are low. P3 onwards were briefed without a brief-sent row, so
only their finishing times are known: the first ten packages finished
between 23:33 on 2026-11-07 and 09:13 on 2026-11-08, ten hours after the
charter, and P7b at about 13:50, its CBMC gate alone taking two and a
half hours.

## What the numbers say

* **No package met the 50 to 100 call target.** The smallest took about
  118 calls (PD), the median about 150, and the eleven together about
1,830.
  Taking the estimates at face value, the typical package was half again
  over the target's top; allowing for the estimates' low bias, nearer
  double.
* **The largest packages were the ones with a new tool or a second core.**
  P7a (a new verification tool and its runner), P5 (two cores) and P2
  (the capability table, the largest core) took 208 to 244 calls each;
  P7b, three harnesses over three cores and two records, about 180.
* **Budget integration did not fit one package.** P4 stopped at a design
  gap and was finished in two more (P4b, P4c): about 422 calls over three
  agents, three times the median package.
* **Gate stalls cost calls.** P1's agent stalled twice waiting on gates,
  and P5 lost about 40 minutes to the atos symbolizer hang that the
  sanitizer environment has since removed.

For GK1, the numbers suggest planning a kernel core at about 150 calls
when it is one core with known design, and splitting a package that adds a
new tool or touches two cores before it starts, rather than after it
overruns.
