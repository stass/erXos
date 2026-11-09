/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The generated ui_wire.ts on its own: what its writers must refuse, and a
 * short run of its readers' fuzz target. Its parity with the Erlang and C
 * readers and writers is test/host/erx_ui_wire_test.rb's.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  EVENT_TEXT_MAX,
  PIXELS_DATA_MAX,
  PROPERTIES,
  read,
  readReport,
  writeEvent,
  writePixels,
  writeRecord,
  type Prop,
  type UIRecord,
} from '../src/generated/ui_wire.ts';
import { REPORT_SEEDS, SEEDS, fuzz } from './ui_wire_fuzz.ts';

const event = [...PROPERTIES.values()].find((type) => type.form === 'event')?.name ?? '';
const other = [...PROPERTIES.values()].find((type) => type.form !== 'event')?.name ?? '';

test('the writer refuses what the form cannot hold', () => {
  const refused: [number, string, Parameters<typeof writeEvent>[2]][] = [
    [0, event, { tag: 'none' }],
    [2 ** 32, event, { tag: 'none' }],
    [1.5, event, { tag: 'none' }],
    [1, other, { tag: 'none' }],
    [1, 'constructor', { tag: 'none' }],
    [1, event, { tag: 'integer', value: 2 ** 31 }],
    [1, event, { tag: 'integer', value: 0.5 }],
    [1, event, { tag: 'text', value: Uint8Array.of(0x61, 0xc0, 0x80) }],
    [1, event, { tag: 'text', value: Uint8Array.of(0xed, 0xa0, 0x80) }],
    [1, event, { tag: 'text', value: new Uint8Array(EVENT_TEXT_MAX + 1).fill(0x61) }],
  ];
  for (const [node, name, detail] of refused) assert.equal(writeEvent(node, name, detail), null, `${node} ${name} ${detail.tag}`);
  assert.notEqual(writeEvent(1, event, { tag: 'text', value: new Uint8Array(EVENT_TEXT_MAX).fill(0x61) }), null);
  assert.equal(writePixels(0, 0, 1, 1, new Uint8Array(PIXELS_DATA_MAX + 1)), null);
  assert.equal(writePixels(65536, 0, 1, 1, new Uint8Array(4)), null);
  assert.notEqual(writePixels(0, 0, 1, 1, new Uint8Array(PIXELS_DATA_MAX)), null);
});

test('the record writer refuses what a reader refuses', () => {
  const own = { status: 'ok', reporter: 'own', stopgap: '', timeoutMs: 0 } as const;
  const visible = { ...own, name: 'visible', number: PROPERTIES.get('visible')?.number ?? 0, form: 'boolean', value: true } as const;
  const text = PROPERTIES.get('text')?.number ?? 0;
  const label = (props: readonly Prop<Uint8Array>[]): UIRecord<Uint8Array> =>
    ({ tag: 'insert', node: 1, parent: 0, index: 0, kind: 'label', props });
  assert.notEqual(writeRecord(label([visible])), null);
  const refused: UIRecord<Uint8Array>[] = [
    { tag: 'remove', node: 0 },
    { ...label([]), kind: 'nothing' },
    label([visible, visible]),
    label([{ ...visible, number: visible.number + 1 }]),
    label([{ ...visible, status: 'unknown', value: null }]),
    label([{ ...own, name: 'text', number: text, form: 'text', reporter: 'kernel', status: 'timeout', value: null }]),
    label([{ ...own, name: 'text', number: text, form: 'text', value: Uint8Array.of(0xc0, 0x80) }]),
    { tag: 'set', node: 1, props: [], removed: ['visible', 'visible'] },
    { tag: 'input', input: { form: 'key', down: true, code: 0, rune: 0xd800 } },
    { tag: 'move', node: 1, index: 65536 },
  ];
  for (const record of refused) assert.equal(writeRecord(record), null, JSON.stringify(record));
});

test('the fuzz seeds are records the readers accept', () => {
  for (const seed of SEEDS) assert.equal(read(seed).result, 'ok', Buffer.from(seed).toString('hex'));
  for (const seed of REPORT_SEEDS) assert.equal(readReport(seed).result, 'ok', Buffer.from(seed).toString('hex'));
});

test('the reader survives a short fuzz run', () => {
  assert.equal(fuzz(1, 20_000), null);
});
