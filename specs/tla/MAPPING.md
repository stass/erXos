# Property mappings

| Model/property | Scope | Implementation and evidence |
| --- | --- | --- |
| RunnerSmoke / Bounded | counter 0..2 in good mode; 0..3 in broken mode | `TlcOutput.classify` distinguishes completed search from the named safety failure; host fixtures and real pinned-TLC runs |
| RunnerSmoke / initial Bounded violation | initial counter 3 | initial-state diagnostic preserves the exact invariant and tool failure status |
| RunnerSmoke / NotReached | counter reaches 2 | expected failure witnesses the path and checks exact property identity |

These are harness fixtures with no erXos protocol implementation mapping.
The protocol model owners add state/action/assumption mappings alongside
their real mechanisms.
