/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * W2 in the browser (docs/design-web.md, "Invariants"): the attributed-text
 * corpus, sent by the machine as a record's kind, its attribute names, its
 * values and its children's names, reaches the page as text and escape
 * tokens, and none of it becomes an element. A Text that wrote its bytes as
 * markup would create the corpus's elements, or, under the front end's
 * Trusted Types policy, throw.
 */

import type { Datum } from '../../src/generated/proto.ts';
import { expect, machineRecord, test, text } from './machine.ts';

/* Each corpus entry, as bytes and as the page must show it. */
const CORPUS: readonly (readonly [string | Uint8Array, string])[] = [
  ['<script>window.erxRan = "script"</script>', '<script>window.erxRan = "script"</script>'],
  ['<img src=x onerror="window.erxRan = \'img\'">', '<img src=x onerror="window.erxRan = \'img\'">'],
  ['<b>bold</b>&amp;', '<b>bold</b>&amp;'],
  ['right\u202eleft', 'right<U+202E>left'],
  ['zero\u200bwidth', 'zero<U+200B>width'],
  ['c1\u009b1m', 'c1<U+009B>1m'],
  [Uint8Array.of(0x62, 0x61, 0x64, 0xc0, 0xaf), 'bad<0xC0><0xAF>'],
];

const values: Datum[] = CORPUS.map(([bytes]) => ({ tag: 'text', bytes: text(bytes) }));

test.use({
  record: machineRecord(
    CORPUS.map(([bytes], at) => ({ key: text(bytes), reporter: { tag: 'kernel' }, status: { tag: 'ok' }, value: values[at] as Datum })),
    { completeness: 'complete', names: CORPUS.map(([bytes]) => ({ tag: 'atom', name: text(bytes) })) },
    text('<script>window.erxRan = "kind"</script>'),
  ),
});

test('the attributed-text corpus renders as text, with no element created', async ({ page }) => {
  await page.goto('/');
  const main = page.locator('main');
  await expect(main.getByRole('table')).toBeVisible();
  const shown = await main.innerText();
  for (const [, expected] of CORPUS) expect(shown).toContain(expected);
  expect(shown).toContain('<script>window.erxRan = "kind"</script>');
  const tokens = await main.locator('.token').allInnerTexts();
  for (const token of ['<U+202E>', '<U+200B>', '<U+009B>', '<0xC0>']) expect(tokens).toContain(token);

  // The page's only elements of the corpus's kinds are the client's own script.
  const made = await page.evaluate(() => ({
    scripts: [...document.scripts].map((script) => script.getAttribute('src')),
    elements: document.querySelectorAll('img, b, main script').length,
    ran: (window as { erxRan?: unknown }).erxRan,
  }));
  expect(made.scripts).toHaveLength(1);
  expect(made.scripts[0]).toMatch(/^\/client-[0-9a-f]{16}\.js$/);
  expect(made.elements).toBe(0);
  expect(made.ran).toBeUndefined();
});
