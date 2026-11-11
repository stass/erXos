/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's routes (docs/design-web.md, "URLs"): each URL form, the paths
 * that name nothing, links from names the machine sent, and the router's fuzz
 * target for a short budget.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { WEB_PATH_SEGMENTS_MAX, WEB_SEGMENT_MAX } from '../src/generated/proto.ts';
import { Route, hrefOf, parseRoute, pathRoute, presentRoute } from '../src/routes.ts';
import { MachineText } from '../src/text.ts';
import { fuzz } from './routes_fuzz.ts';

const text = (value: string): MachineText => new MachineText(new TextEncoder().encode(value));
const valueOf = (pathname: string): unknown => parseRoute(pathname)?.value;

test('each URL form names its route and is written back as itself', () => {
  const forms: [string, unknown][] = [
    ['/', { kind: 'home' }],
    ['/proc/domains/1', { kind: 'proc', path: ['domains', '1'] }],
    ['/proc/processes/0.1.2', { kind: 'proc', path: ['processes', '0.1.2'] }],
    ['/proc/a%2Fb/%2Ehidden/a%2E', { kind: 'proc', path: ['a%2Fb', '%2Ehidden', 'a%2E'] }],
    ['/pid/0.1.2', { kind: 'present', type: 'pid', text: '0.1.2', path: ['processes', '0.1.2'] }],
    ['/module/1/lists', { kind: 'present', type: 'module', text: '1/lists', path: ['domains', '1', 'modules', 'lists'] }],
    ['/module/3/a%252Eb', { kind: 'present', type: 'module', text: '3/a%2Eb', path: ['domains', '3', 'modules', 'a%2Eb'] }],
    ['/module/3/%252E%252E', { kind: 'present', type: 'module', text: '3/%2E%2E', path: ['domains', '3', 'modules', '%2E%2E'] }],
    ['/ui/0', { kind: 'ui', number: 0 }],
    ['/ui/4294967295', { kind: 'ui', number: 4294967295 }],
    ['/trace', { kind: 'trace' }],
    ['/login', { kind: 'login' }],
  ];
  for (const [pathname, value] of forms) {
    const route = parseRoute(pathname);
    assert.deepEqual(route?.value, value, pathname);
    assert.equal(hrefOf(route as Route), pathname);
  }
});

test('a path that names nothing has no route', () => {
  const nothing = [
    '', 'proc/a', '/proc', '/proc/', '/proc/a/', '/proc/a//b', '/ws', '/trace/', '/trace/x', '/login/x',
    '/ui', '/ui/', '/ui/007', '/ui/-1', '/ui/1/2', '/ui/4294967296', '/ui/1e3', '/pid', '/pid/', '/unknown/x',
    '/proc/a%2fb', '/proc/a%', '/proc/a%4', '/proc/a b', '/proc/a\\b', '/proc/a?b', '/proc/\u00e9',
    '/module/1', '/module/1/lists/x', '/module//lists', '/module/3/a%2Eb', '/module/3/a%25',
  ];
  for (const pathname of nothing) assert.equal(valueOf(pathname), undefined, pathname);
});

test('a segment a URL parser reads as a dot segment names nothing, in either case', () => {
  for (const dot of ['.', '..', '%2E', '%2e', '%2E%2E', '%2e%2e', '%2E%2e', '.%2E', '%2e.', '.%2e']) {
    assert.equal(valueOf(`/proc/a/${dot}`), undefined, dot);
    assert.equal(valueOf(`/proc/${dot}/a`), undefined, dot);
    assert.equal(valueOf(`/pid/${dot}`), undefined, dot);
    assert.equal(valueOf(`/module/1/${dot}`), undefined, dot);
    assert.equal(new URL(`/proc/a/${dot}`, 'http://127.0.0.1:1').pathname.endsWith(dot), false, dot);
  }
  assert.equal(pathRoute([text('%2E%2E')]), undefined);
  assert.equal(presentRoute(text('pid'), text('.')), undefined);
  const named = presentRoute(text('module'), text('3/%2E%2E'));
  assert.equal(named === undefined ? undefined : hrefOf(named), '/module/3/%252E%252E');
});

test('a path holds at most its bounds of segments and bytes', () => {
  const segments = (count: number): string => `/proc${'/a'.repeat(count)}`;
  assert.notEqual(valueOf(segments(WEB_PATH_SEGMENTS_MAX)), undefined);
  assert.equal(valueOf(segments(WEB_PATH_SEGMENTS_MAX + 1)), undefined);
  assert.notEqual(valueOf(`/proc/${'x'.repeat(WEB_SEGMENT_MAX)}`), undefined);
  assert.equal(valueOf(`/proc/${'x'.repeat(WEB_SEGMENT_MAX + 1)}`), undefined);
});

test('a name the machine sent links only when its escape is the canonical name', () => {
  const route = pathRoute([text('domains'), text('1'), text('modules'), text('erx%2Eshell')]);
  assert.equal(route === undefined ? undefined : hrefOf(route), '/proc/domains/1/modules/erx%2Eshell');
  assert.equal(hrefOf(pathRoute([]) as Route), '/');
  for (const bad of ['a/b', 'a\nb', 'a\u202eb', 'a b', 'a%2f', '<a>', '', '\u00e9']) {
    assert.equal(pathRoute([text('domains'), text(bad)]), undefined, JSON.stringify(bad));
  }
  assert.equal(pathRoute([new MachineText(Uint8Array.of(0x61, 0xff))]), undefined);
  const present = presentRoute(text('module'), text('1/lists'));
  assert.equal(present === undefined ? undefined : hrefOf(present), '/module/1/lists');
  assert.equal(presentRoute(text('proc'), text('1')), undefined);
  assert.equal(presentRoute(text('pid'), text('0.1.2/3')), undefined);
});

test('a route is made only by the checks and does not change', () => {
  const Unchecked = Route as unknown as new (token: symbol, value: unknown) => Route;
  assert.throws(() => new Unchecked(Symbol('route'), { kind: 'proc', path: ['..'] }), TypeError);
  const route = parseRoute('/proc/a') as Route;
  assert.throws(() => {
    (route.value as { path: string[] }).path.push('..');
  }, TypeError);
  assert.throws(() => {
    (route as unknown as { value: unknown }).value = { kind: 'proc', path: ['..'] };
  }, TypeError);
  const forged = { value: { kind: 'present', type: '', text: '/evil.example/x' } } as unknown as Route;
  assert.throws(() => hrefOf(forged), TypeError);
  assert.equal(Route.is(forged), false);
  assert.throws(() => {
    (route.value as { kind: string }).kind = 'home';
  }, TypeError);
  assert.equal(Route.ui(-1), undefined);
  assert.equal(Route.ui(1.5), undefined);
  assert.equal(Route.ui(2 ** 32), undefined);
});

test('the router fuzz target passes a short budget', () => {
  assert.equal(fuzz(1, 20_000), null);
});
