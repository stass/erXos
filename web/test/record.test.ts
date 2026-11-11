/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The record view's rows (docs/design-web.md, "The client", Views): each
 * attribute's name, its value or, when its status is not ok, the status's
 * token as erx_render prints it (W7), and its reporter; the children with
 * their completeness. Machine text stays MachineText to the end (W2).
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { type Attr, type Datum, type Status, type WireRecord, machineText } from '../src/generated/proto.ts';
import { type Part, childrenParts, recordRows } from '../src/record.ts';
import { escapedText } from '../src/text.ts';

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);
const text = (value: string) => machineText(utf8(value));

/* A part as the page shows its text, the kind marking what is not machine text. */
const shown = (parts: readonly Part[]): string =>
  parts.map((part) => {
    switch (part.kind) {
      case 'text': return escapedText(part.text.runs());
      case 'plain': return part.text;
      case 'token': return `token:${part.text}`;
      case 'present': return escapedText(part.text.runs());
    }
  }).join('');

const attr = (key: string, status: Status, value: Datum, reporter: Attr['reporter'] = { tag: 'kernel' }): Attr =>
  ({ key: text(key), reporter, status, value });

const record = (attrs: Attr[], children: WireRecord['children']): WireRecord =>
  ({ path: [], kind: text('machine'), id: { tag: 'int', digits: 0n }, attrs, children });

test('ok values show as data; other statuses show only their tokens', () => {
  const value: Datum = { tag: 'int', digits: 4n };
  const rows = recordRows(record([
    attr('cpus', { tag: 'ok' }, value),
    attr('memory', { tag: 'partial' }, value, { tag: 'service' }),
    attr('uptime', { tag: 'unknown' }, value, { tag: 'runtime' }),
    attr('load', { tag: 'unsupported' }, value, { tag: 'stopgap', name: 'liberx_pool' }),
    attr('ticks', { tag: 'timeout', ms: 500 }, value),
    attr('build', { tag: 'error' }, value),
  ], { completeness: 'complete', names: [] }));
  assert.deepEqual(rows.map((row) => [escapedText(row.key.runs()), shown(row.value), row.reporter]), [
    ['cpus', '4', 'kernel'],
    ['memory', 'token:[partial]', 'service'],
    ['uptime', 'token:[unknown]', 'runtime'],
    ['load', 'token:[unsupported]', 'stopgap liberx_pool'],
    ['ticks', 'token:[timeout 500]', 'kernel'],
    ['build', 'token:[error]', 'kernel'],
  ]);
});

test('compound values keep each machine text apart', () => {
  const value: Datum = {
    tag: 'tuple',
    items: [
      { tag: 'atom', name: text('ok') },
      { tag: 'list', items: [{ tag: 'text', bytes: text('<b>\u202e') }, { tag: 'printed', text: text('#Ref<0.1>') }] },
      { tag: 'present', type: text('pid'), text: text('<0.42.0>') },
    ],
  };
  const [row] = recordRows(record([attr('state', { tag: 'ok' }, value)], { completeness: 'complete', names: [] }));
  assert.ok(row !== undefined);
  assert.equal(shown(row.value), '{ok, [<b><U+202E>, #Ref<0.1>], <0.42.0>}');
  assert.ok(row.value.filter((part) => part.kind === 'plain').every((part) => /^[[\]{}, ]+$/.test(part.text)));
});

test('children show their names and their completeness', () => {
  const names: Datum[] = [{ tag: 'atom', name: text('cpus') }, { tag: 'int', digits: 3n }];
  assert.equal(shown(childrenParts({ completeness: 'complete', names })), 'cpus, 3');
  assert.equal(shown(childrenParts({ completeness: 'partial', names })), 'cpus, 3 token:[partial]');
  assert.equal(shown(childrenParts({ completeness: 'unknown', names: [] })), 'token:[unknown]');
  assert.equal(shown(childrenParts({ completeness: 'complete', names: [] })), '');
});
