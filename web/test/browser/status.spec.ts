/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * W7 in the browser (docs/design-web.md, "Invariants"): never fabricate. A
 * value whose status is not ok shows its token, as erx_render prints it, and
 * never the value it carries; a partial listing is marked partial; and when
 * the machine stops, the view says it is stale within the ping interval.
 */

import { WEB_PING_MS } from '../../src/generated/proto.ts';
import { expect, machineRecord, test, text } from './machine.ts';

/* A value no status but ok may show: it appears on the page only if a status is printed as a value. */
const HIDDEN = 987_654_321n;
const hidden = { tag: 'int', digits: HIDDEN } as const;

test.use({
  record: machineRecord([
    { key: text('cpus'), reporter: { tag: 'kernel' }, status: { tag: 'ok' }, value: { tag: 'int', digits: 4n } },
    { key: text('memory'), reporter: { tag: 'service' }, status: { tag: 'partial' }, value: hidden },
    { key: text('uptime'), reporter: { tag: 'runtime' }, status: { tag: 'unknown' }, value: hidden },
    { key: text('ticks'), reporter: { tag: 'kernel' }, status: { tag: 'timeout', ms: 500 }, value: hidden },
  ], { completeness: 'partial', names: [{ tag: 'atom', name: text('cpus') }] }),
});

test('values that are not ok show their tokens, never their values', async ({ page }) => {
  await page.goto('/');
  const rows = page.locator('main table tbody tr');
  await expect(rows).toHaveCount(4);
  await expect(rows.nth(0)).toContainText('4');
  await expect(rows.nth(1).locator('.token')).toHaveText('[partial]');
  await expect(rows.nth(2).locator('.token')).toHaveText('[unknown]');
  await expect(rows.nth(3).locator('.token')).toHaveText('[timeout 500]');
  await expect(page.locator('main')).toContainText('cpus [partial]');
  await expect(page.locator('main')).not.toContainText(HIDDEN.toString());
});

test('a stopped machine marks the view stale within the ping interval', async ({ page, machine }) => {
  await page.goto('/');
  await expect(page.locator('main table')).toBeVisible();
  await expect(page.locator('main')).not.toContainText('stale since');
  machine.stop();
  await expect(page.locator('main .notice')).toContainText('stale since', { timeout: WEB_PING_MS });
  // The record stays, marked, rather than vanish or pass for current.
  await expect(page.locator('main table')).toBeVisible();
});
