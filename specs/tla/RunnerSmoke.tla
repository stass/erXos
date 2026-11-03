\* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
\* SPDX-License-Identifier: BSD-2-Clause
--------------------------- MODULE RunnerSmoke ---------------------------
EXTENDS Naturals

CONSTANT Limit
VARIABLE count

Init == count = 0
BadInit == count = 3
Next == IF count < Limit THEN count' = count + 1 ELSE count' = 0
Spec == Init /\ [][Next]_count

Bounded == count \in 0..2
NotReached == count # 2
=============================================================================
