/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * W7 in the browser (docs/design-web.md, "Invariants"): never fabricate. A
 * value whose status is not ok shows its token, as erx_render prints it, and
 * never the value it carries; a partial listing is marked partial; and when
 * the machine stops, the view says it is stale within the ping interval. The
 * front panel lights only what the record holds, each attribute by its status.
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
  await expect(rows.nth(1).locator('.status-token')).toHaveText('[partial]');
  await expect(rows.nth(2).locator('.status-token')).toHaveText('[unknown]');
  await expect(rows.nth(3).locator('.status-token')).toHaveText('[timeout 500]');
  await expect(page.locator('main .listing li')).toHaveText(['cpus', '[partial]']);
  await expect(page.locator('.front-panel .bank-children .bank-label')).toHaveText('1 children [partial]');
  await expect(page.locator('main')).not.toContainText(HIDDEN.toString());
  // The front panel lights each attribute by its status, and the one child the listing names.
  const lamps = page.locator('.front-panel .bank-attributes .led');
  await expect(lamps).toHaveCount(4);
  for (const [at, lamp] of ['ok', 'partial', 'unknown', 'timeout'].entries()) {
    await expect(lamps.nth(at)).toHaveClass(new RegExp(`(^| )lamp-${lamp}( |$)`));
  }
  await expect(page.locator('.front-panel .bank-children .led')).toHaveCount(1);
});

test('a stopped machine marks the view stale within the ping interval', async ({ page, machine }) => {
  await page.goto('/');
  await expect(page.locator('main table')).toBeVisible();
  await expect(page.locator('main')).not.toContainText('stale since');
  machine.stop();
  await expect(page.locator('main .notice')).toContainText('stale since', { timeout: WEB_PING_MS });
  await expect(page.locator('main .strip')).toHaveClass(/\bstrip-stale\b/);
  // The record stays, marked, rather than vanish or pass for current.
  await expect(page.locator('main table')).toBeVisible();
});

test.describe('what the page says of values it cannot show', () => {
  test.use({
    record: machineRecord([
      { key: text('uptime'), reporter: { tag: 'kernel' }, status: { tag: 'unsupported' }, value: { tag: 'list', items: [] } },
      { key: text('used'), reporter: { tag: 'stopgap', name: 'liberx_pool' }, status: { tag: 'ok' }, value: { tag: 'int', digits: 7n } },
    ]),
  });

  test('an unsupported value is explained and a stopgap reporter shows its scope', async ({ page }) => {
    await page.goto('/');
    const notes = page.locator('main .notes p');
    await expect(notes).toHaveCount(2);
    await expect(notes.nth(0)).toHaveText(/^\[unsupported\] kernel: the kernel interface does not report it/);
    await expect(notes.nth(1)).toHaveText(/^stopgap liberx_pool \(root pool\): pages of the root's pool/);
  });
});

test.describe('a record with nothing to explain', () => {
  test.use({
    record: machineRecord([
      { key: text('cpus'), reporter: { tag: 'kernel' }, status: { tag: 'ok' }, value: { tag: 'int', digits: 4n } },
    ]),
  });

  test('has no notes', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('main table tbody tr')).toHaveCount(1);
    await expect(page.locator('main .notes')).toHaveCount(0);
  });
});
