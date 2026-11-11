/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The eval probe of policy.spec.ts, which probe.html loads: a script the
 * policy lets run, as the front end serves it from its own origin, tries a
 * string eval, which the policy forbids, and records on the page what
 * happened. A script the test ran itself would not do: Playwright's evaluate
 * goes through the DevTools protocol, which the policy does not bind.
 */
const root = document.documentElement;
root.dataset.self = 'ran';
try {
  root.dataset.evaluated = String((0, eval)('1 + 1'));
} catch (error) {
  root.dataset.evalRefused = error.name;
}
