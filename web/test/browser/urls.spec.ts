/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * W6 in the browser (docs/design-web.md, "Invariants"): opening a URL changes
 * nothing on the machine. Every URL form, and a reconnect with each page
 * open, sends the machine no open of a trace and no UI event; a trace starts
 * only from a user's action on the trace page.
 */

import type { Browser } from '../../src/generated/proto.ts';
import { RETRY_FIRST_MS } from '../../src/connection.ts';
import { type StandIn, expect, machineRecord, test } from './machine.ts';

/* One path of each form the router reads, and of forms it refuses. */
const FORMS = [
  '/', '/proc/domains/1', '/proc/a%2Fb/%2Ehidden', '/pid/0.1.2', '/module/1/lists', '/ui/0', '/trace', '/login',
  '/proc', '/ui/00', '/trace/1', '/domain/..', '/nowhere',
];

/* What the client sent that acts on the machine: a trace opened, or a UI event. */
const acting = (heard: readonly Browser[]): Browser[] =>
  heard.filter((message) => (message.tag === 'open' && message.target.tag === 'trace') || message.tag === 'event');

/*
 * The paths whose page must show a view, and so connect: the home page, and
 * a path the browser's URL parser reads as it. Another form may connect too;
 * one that does is reconnected like these.
 */
const CONNECTING = new Set(['/']);

/*
 * The page has rendered and, if it shows a view, connected and opened it;
 * then the connections drop and come back, so what a reconnect sends is
 * heard too.
 */
async function loadAndReconnect(page: import('@playwright/test').Page, machine: StandIn, path: string): Promise<void> {
  await page.goto(path);
  await expect(page.locator('body > div > *').first()).toBeVisible();
  const opened = () => machine.heard.filter((message) => message.tag === 'open').length;
  if (CONNECTING.has(new URL(page.url()).pathname)) await expect.poll(opened).toBeGreaterThan(0);
  else await page.waitForTimeout(RETRY_FIRST_MS);
  const before = opened();
  // A page that shows no view opens nothing, and has nothing to reconnect.
  if (before === 0) return;
  machine.drop();
  await expect.poll(opened, { timeout: RETRY_FIRST_MS * 4 }).toBeGreaterThan(before);
}

test.use({ record: machineRecord([]) });

for (const path of FORMS) {
  test(`${path} starts no trace and sends no event, loaded or reconnected`, async ({ page, machine }) => {
    await loadAndReconnect(page, machine, path);
    expect(acting(machine.heard)).toEqual([]);
  });
}
