/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * W3 in the browser (docs/design-web.md, "Invariants"): the browser runs only
 * the client's own files. The policy under test is the one the host tool's
 * front end writes on every file it serves (Erx::Web::Http::POLICY), which the
 * runner passes in ERX_WEB_POLICY; these tests find it on every response and
 * probe it, and do not restate it. The
 * probes are probe.html, with an inline script, and probe-eval.js, which
 * tries a string eval; the runner serves both beside the client's files, so
 * they arrive with the same headers.
 */

import { expect, test } from './machine.ts';

/* The page's reports of what the policy blocked: each violation's directive and what it blocked. */
async function watchViolations(page: import('@playwright/test').Page): Promise<void> {
  await page.addInitScript(() => {
    const seen: string[] = [];
    (window as { erxViolations?: string[] }).erxViolations = seen;
    document.addEventListener('securitypolicyviolation', (event) => seen.push(`${event.effectiveDirective} ${event.blockedURI}`));
  });
}

/* The policy the front end writes, as the runner read it from Erx::Web::Http. */
const POLICY = process.env.ERX_WEB_POLICY ?? '';

const violations = (page: import('@playwright/test').Page) =>
  page.evaluate(() => (window as { erxViolations?: string[] }).erxViolations ?? []);

test('every file the client loads carries the front end\'s policy, and the client trips none of it', async ({ page }) => {
  await watchViolations(page);
  const policies = new Map<string, string | undefined>();
  page.on('response', (response) => policies.set(new URL(response.url()).pathname, response.headers()['content-security-policy']));
  await page.goto('/');
  await expect(page.locator('main')).toBeVisible();
  // The page, its script and its stylesheet at least.
  expect(policies.has('/')).toBe(true);
  expect(policies.size).toBeGreaterThanOrEqual(3);
  expect(POLICY).not.toBe('');
  for (const [path, policy] of policies) expect(policy, path).toBe(POLICY);
  expect(await violations(page)).toEqual([]);
});

/* The probe page: what ran, and what the policy reported blocking. */
async function probe(page: import('@playwright/test').Page) {
  await watchViolations(page);
  await page.goto('/probe.html');
  await expect(page.locator('body')).toHaveText('probe');
  const ran = await page.evaluate(() => ({ ...document.documentElement.dataset }));
  // The control: a script from the front end's own origin runs.
  expect(ran.self).toBe('ran');
  return ran;
}

test('a seeded inline script is blocked and reported', async ({ page }) => {
  const ran = await probe(page);
  expect(ran.inline).toBeUndefined();
  await expect.poll(() => violations(page)).toContain('script-src-elem inline');
});

test('a seeded eval is blocked and reported', async ({ page }) => {
  const ran = await probe(page);
  expect(ran.evaluated).toBeUndefined();
  expect(ran.evalRefused).toBeDefined();
  await expect.poll(() => violations(page)).toEqual(expect.arrayContaining([expect.stringMatching(/ (eval|trusted-types-sink)$/)]));
});
