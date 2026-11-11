/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The fuzz target of the client's router (web/src/routes.ts), whose input is
 * any path a browser's address bar or another page's link can name. Each
 * round builds a path from pieces near the router's rules (the fixed routes,
 * presentation types, dot segments in every spelling, percent encodings in
 * both cases, numbers at the u32 bound, characters a URL parser rewrites) and
 * checks that parseRoute returns and never throws, and that a route it
 * returns is written back by hrefOf as the same path, so every route has one
 * URL. It also makes routes from random entry names through the machine's
 * side, pathRoute and presentRoute, and checks that each link hrefOf writes
 * is read back as the same route and that a browser URL parser leaves the
 * link's path as written: same origin, no dot segment removed, nothing
 * percent-encoded again.
 *
 * Run as "node routes_fuzz.ts SEED ROUNDS"; tools/fuzz/erx_web_routes.rb runs
 * it for make check-fuzz, and routes.test.ts for a short budget.
 */

import { procName } from '../src/names.ts';
import { hrefOf, parseRoute, pathRoute, presentRoute, type Route } from '../src/routes.ts';
import { MachineText } from '../src/text.ts';
import { generator } from './text_fuzz.ts';

const BASE = 'http://127.0.0.1:8080';
const PIECES = [
  'proc', 'ui', 'trace', 'login', 'ws', 'pid', 'domain', 'module', 'group', 'budget', 'domains', 'processes',
  '.', '..', '%2E', '%2e', '%2E%2E', '.%2E', '%2e.', '%2F', '%2f', '%', '%4', '%41', '%C3%A9', 'a', 'Z', '0.1.2',
  '0', '00', '007', '1', '4294967295', '4294967296', '-1', ':', '@', '=', ',', '+', '_', '-', '\\', '?', '#',
  ' ', '\t', '"', '<', '\u00e9', '\u202e', '/', '//', '', 'x'.repeat(256), 'x'.repeat(257),
];
const PARTS = ['a', '1', '0.1.2', 'lists', '%2E', '%2e', '.', '..', '%25', '%252E', '%252E%252E', 'a%2Fb', ''];
const VALID_PARTS = ['a', '1', '0.1.2', 'lists', '%25', '%252E', 'a%2Fb'];
const SEGMENTS = ['domains', 'processes', 'modules', '1', '0.1.2', 'erx_shell', '.', '..', '/', '%', 'a.b', ''];

function pick<T>(next: () => number, items: readonly T[]): T {
  return items[next() % items.length] as T;
}

/* A path of random pieces, mostly naming nothing. */
function loosePath(next: () => number): string {
  const count = next() % 20;
  let text = next() % 8 === 0 ? '' : '/';
  for (let index = 0; index < count; index += 1) {
    text += pick(next, PIECES);
    if (next() % 3 !== 0) text += '/';
  }
  return text;
}

/* A path shaped like a route, near its bounds: so a fault in a check that admits shows. */
function shapedPath(next: () => number): string {
  const pool = next() % 2 === 0 ? VALID_PARTS : PARTS;
  const parts = (count: number): string => Array.from({ length: count }, () => pick(next, pool)).join('/');
  switch (next() % 3) {
    case 0:
      return `/proc/${parts(14 + (next() % 4))}`;
    case 1:
      return `/ui/${pick(next, ['0', '00', '01', '7', '4294967295', '4294967296', '99999999999'])}`;
    default:
      return `/${pick(next, ['pid', 'domain', 'module', 'group', 'budget'])}/${parts(1 + (next() % 2))}`;
  }
}

const path = (next: () => number): string => (next() % 2 === 0 ? loosePath(next) : shapedPath(next));

/* A random entry name as the machine writes one: canonical bytes, some of them dots or percent signs. */
function name(next: () => number): MachineText {
  const raw = Array.from({ length: next() % 6 }, () => pick(next, SEGMENTS)).join('');
  const bytes = new TextEncoder().encode(raw);
  const text = next() % 4 === 0 ? raw : procName(bytes);
  return new MachineText(new TextEncoder().encode(text));
}

function machineRoute(next: () => number): Route | undefined {
  if (next() % 2 === 0) return pathRoute(Array.from({ length: next() % 18 }, () => name(next)));
  const type = new MachineText(new TextEncoder().encode(pick(next, ['pid', 'domain', 'module', 'proc', 'x'])));
  const parts = Array.from({ length: 1 + (next() % 3) }, () => pick(next, ['0.1.2', '1', 'lists', '%2E', '..', '']));
  return presentRoute(type, new MachineText(new TextEncoder().encode(parts.join('/'))));
}

/* What is wrong with a link hrefOf wrote for route, or null. */
function linkFault(route: Route): string | null {
  const href = hrefOf(route);
  if (!href.startsWith('/') || href.startsWith('//') || href.includes('\\')) return `${href}: not a path of this origin`;
  const url = new URL(href, BASE);
  if (url.origin !== BASE || url.pathname !== href || url.search !== '' || url.hash !== '') {
    return `${href}: a browser reads it as ${url.href}`;
  }
  const back = parseRoute(href);
  if (back === undefined || JSON.stringify(back.value) !== JSON.stringify(route.value)) {
    return `${href}: read back as ${back === undefined ? 'nothing' : JSON.stringify(back.value)}`;
  }
  return null;
}

export function fuzz(seed: number, rounds: number): string | null {
  const next = generator(seed);
  for (let round = 0; round < rounds; round += 1) {
    const pathname = path(next);
    let route: Route | undefined;
    try {
      route = parseRoute(pathname);
    } catch (error) {
      return `${JSON.stringify(pathname)}: parseRoute threw ${String(error)}`;
    }
    if (route !== undefined && hrefOf(route) !== pathname) {
      return `${JSON.stringify(pathname)}: written back as ${hrefOf(route)}`;
    }
    const fault = route === undefined ? null : linkFault(route);
    if (fault !== null) return fault;
    const made = machineRoute(next);
    const madeFault = made === undefined ? null : linkFault(made);
    if (madeFault !== null) return madeFault;
  }
  return null;
}

if (import.meta.main) {
  const [seed, rounds] = process.argv.slice(2).map(Number);
  const failure = fuzz(seed, rounds);
  if (failure !== null) {
    console.log(`fuzz: ${failure}`);
    process.exit(1);
  }
  console.log(`fuzz: ${rounds} rounds ok`);
}
