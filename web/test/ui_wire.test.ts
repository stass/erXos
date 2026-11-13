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
  DAMAGE_MAX,
  EVENT_TEXT_MAX,
  PROPERTIES,
  read,
  readReport,
  writeDamage,
  writeEvent,
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
  const rect = { x: 0, y: 0, width: 1, height: 1 };
  assert.equal(writeDamage(1, 1, []), null);
  assert.equal(writeDamage(1, 1, Array.from({ length: DAMAGE_MAX + 1 }, () => rect)), null);
  assert.equal(writeDamage(65536, 1, [rect]), null);
  assert.equal(writeDamage(65535, 1, [{ ...rect, x: 65536 }]), null);
  assert.equal(writeDamage(1, 1, [{ ...rect, width: 0 }]), null);
  assert.equal(writeDamage(1, 1, [{ ...rect, height: 0 }]), null);
  assert.equal(writeDamage(1, 1, [{ ...rect, x: 1 }]), null);
  assert.equal(writeDamage(1, 1, [{ ...rect, height: 2 }]), null);
  assert.notEqual(writeDamage(1, 1, Array.from({ length: DAMAGE_MAX }, () => rect)), null);
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
    { ...label([]), kind: 'nothing' } as unknown as UIRecord<Uint8Array>,
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

test('a damage rectangle must lie within the size its report names', () => {
  /* Drawn at 2 by 2: a rectangle ending on the edge, then one a column past it and one a row past it. */
  const report = (x: number, y: number, w: number, h: number) =>
    Uint8Array.of(14, 0, 0, 0, 10, 2, 0, 2, 0, 1, x, 0, y, 0, w, 0, h, 0);
  assert.equal(readReport(report(1, 1, 1, 1)).result, 'ok');
  assert.deepEqual(readReport(report(1, 0, 2, 1)), { result: 'bad', reason: 'bad body' });
  assert.deepEqual(readReport(report(0, 1, 1, 2)), { result: 'bad', reason: 'bad body' });
});

test('the reader survives a short fuzz run', () => {
  assert.equal(fuzz(1, 20_000), null);
});
