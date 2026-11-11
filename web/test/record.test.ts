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
import { type Listing, type Part, childrenListing, crumbs, frontPanel, recordRows } from '../src/record.ts';
import { hrefOf, parseRoute } from '../src/routes.ts';
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
      case 'link': return `link:${hrefOf(part.route)}:${escapedText(part.text.runs())}`;
    }
  }).join('');

/* A listing as the page shows it, one entry per cell, cells apart by a bar. */
const listed = (listing: Listing): string =>
  [...listing.names.map(shown), ...(listing.mark === undefined ? [] : [shown([listing.mark])])].join(' | ');

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

test('children show their names, one entry each, and their completeness', () => {
  const pair: Datum = { tag: 'tuple', items: [{ tag: 'atom', name: text('a') }, { tag: 'atom', name: text('b') }] };
  const names: Datum[] = [{ tag: 'text', bytes: text('cpus') }, { tag: 'int', digits: 3n }, pair];
  assert.equal(listed(childrenListing([], { completeness: 'complete', names })), 'link:/proc/cpus:cpus | 3 | {a, b}');
  assert.equal(listed(childrenListing([], { completeness: 'partial', names })), 'link:/proc/cpus:cpus | 3 | {a, b} | token:[partial]');
  // An unknown listing names none, even when it carries names.
  assert.equal(listed(childrenListing([], { completeness: 'unknown', names })), 'token:[unknown]');
  assert.equal(listed(childrenListing([], { completeness: 'complete', names: [] })), '');
});

/*
 * The listing of a session's processes as the GW measurement's fixture holds it:
 * a page of 1,000 pids, each a link that parseRoute reads back as the path of
 * that process below the listing's.
 */
test('a listing of 1,000 children shows 1,000 links, each read back to its path', () => {
  const pids = Array.from({ length: 1000 }, (_, at) => `12.${at + 100}.0`);
  const listing = childrenListing([{ tag: 'text', bytes: text('processes') }],
    { completeness: 'partial', names: pids.map((pid): Datum => ({ tag: 'text', bytes: text(pid) })) });
  const links = listing.names.flat().flatMap((part) => (part.kind === 'link' ? [part] : []));
  assert.equal(links.length, 1000);
  links.forEach((link, at) => {
    assert.deepEqual(parseRoute(hrefOf(link.route))?.value, { kind: 'proc', path: ['processes', pids[at]] });
    assert.equal(escapedText(link.text.runs()), pids[at]);
  });
});

test('a child that makes no route, or below a path that is not names, is text alone', () => {
  const children = (names: string[]) => ({ completeness: 'complete' as const, names: names.map((name): Datum => ({ tag: 'text', bytes: text(name) })) });
  assert.equal(listed(childrenListing([], children(['..', '<b>', 'a/b', '%2e']))), '.. | <b> | a/b | %2e');
  assert.equal(listed(childrenListing([{ tag: 'int', digits: 4n }], children(['threads']))), 'threads');
});

test('each status token carries its status as a lamp', () => {
  const rows = recordRows(record([
    attr('cpus', { tag: 'ok' }, { tag: 'int', digits: 4n }),
    attr('ticks', { tag: 'timeout', ms: 500 }, { tag: 'int', digits: 9n }),
  ], { completeness: 'unknown', names: [] }));
  assert.deepEqual(rows[1]?.value, [{ kind: 'token', text: '[timeout 500]', lamp: 'timeout' }]);
  assert.deepEqual(childrenListing([], { completeness: 'unknown', names: [] }).mark, { kind: 'token', text: '[unknown]', lamp: 'unknown' });
});

test('the front panel lights each attribute by its status and each child, and blinks only what changed', () => {
  const pid = (n: string): Datum => ({ tag: 'text', bytes: text(n) });
  const before = record([
    attr('state', { tag: 'ok' }, { tag: 'atom', name: text('waiting') }),
    attr('heap', { tag: 'ok' }, { tag: 'int', digits: 233n }),
    attr('memory', { tag: 'partial' }, { tag: 'int', digits: 1n }),
  ], { completeness: 'complete', names: [pid('<0.1.0>'), pid('<0.2.0>')] });
  const after = record([
    attr('state', { tag: 'ok' }, { tag: 'atom', name: text('running') }),
    attr('heap', { tag: 'ok' }, { tag: 'int', digits: 233n }),
    // A value that is not ok shows only its token, so a new value under it is no change.
    attr('memory', { tag: 'partial' }, { tag: 'int', digits: 2n }),
    attr('links', { tag: 'unknown' }, { tag: 'list', items: [] }),
  ], { completeness: 'complete', names: [pid('<0.2.0>'), pid('<0.3.0>')] });

  const first = frontPanel(before, undefined);
  assert.deepEqual(first.attrs, [
    { lamp: 'ok', changed: false }, { lamp: 'ok', changed: false }, { lamp: 'partial', changed: false },
  ]);
  assert.deepEqual(first.children, [{ lamp: 'ok', changed: false }, { lamp: 'ok', changed: false }]);

  const next = frontPanel(after, before);
  assert.deepEqual(next.attrs.map((light) => light.changed), [true, false, false, true]);
  assert.deepEqual(next.attrs.map((light) => light.lamp), ['ok', 'ok', 'partial', 'unknown']);
  assert.deepEqual(next.children.map((light) => light.changed), [false, true]);

  // An unknown listing lights no child, whatever names it carries.
  assert.deepEqual(frontPanel({ ...after, children: { ...after.children, completeness: 'unknown' } }, before).children, []);
});

test('the front panel tells a token apart from the same characters as plain text', () => {
  const raw = record([attr('name', { tag: 'ok' }, { tag: 'text', bytes: machineText(new Uint8Array([0xc0])) })],
                     { completeness: 'complete', names: [] });
  const spelled = record([attr('name', { tag: 'ok' }, { tag: 'text', bytes: text('<0xC0>') })], { completeness: 'complete', names: [] });
  assert.deepEqual(frontPanel(spelled, raw).attrs, [{ lamp: 'ok', changed: true }]);
});

test('the trail links every path above a page and the page itself', () => {
  assert.deepEqual(crumbs([]), []);
  assert.deepEqual(crumbs(['processes', '123']).map((crumb) => [crumb.name, hrefOf(crumb.route)]),
                   [['processes', '/proc/processes'], ['123', '/proc/processes/123']]);
});
