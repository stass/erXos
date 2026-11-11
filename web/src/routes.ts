/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's routes (docs/design-web.md, "URLs"): what a URL's path names,
 * and the one function that writes a link, hrefOf.
 *
 * A Route is checked when it is made and cannot be made otherwise: its
 * constructor takes a token private to this module, and its value is an
 * instance private field, so TypeScript reads Route as a nominal type and
 * hrefOf refuses any object that is not one. parseRoute reads a browser's
 * path, and pathRoute and presentRoute read names the machine sent. Every
 * link hrefOf writes is one parseRoute reads back to the same route, which
 * the fuzz target (web/test/routes_fuzz.ts) confirms together with a
 * browser URL parser leaving every link's path unchanged.
 *
 * A /proc path segment is a /proc entry name in /proc's canonical encoding
 * (web/src/names.ts): bytes of A-Z a-z 0-9 _ + , : = @ - and . as
 * themselves, any other byte as % and two upper-case hexadecimal digits.
 * A browser's URL parser reads a segment that decodes to . or .. as a dot
 * segment and removes it, so such a segment names nothing here and is in
 * no link. The machine's own record is at /, so /proc with no segment names
 * nothing, and a path of no segment is the home route.
 *
 * A presentation's URL is /TYPE/TEXT with TEXT its canonical text in the
 * erx: URI encoding, as erx_present:uri/2 writes the link a terminal shows.
 * The canonical text holds only bytes that encoding keeps but %, so TEXT is
 * the canonical text with each % written %25, and a %XX in TEXT other than
 * %25 names nothing. TEXT has no dot segment whatever names it carries,
 * since a canonical text's %2E is %252E there.
 */

import { WEB_PATH_SEGMENTS_MAX, WEB_PRINTED_MAX, WEB_SEGMENT_MAX } from './generated/proto.ts';
import { erxText, presentationPath } from './names.ts';
import { MachineText, escapedText } from './text.ts';

/* What a route names, as the views read it; a presentation's text is canonical. */
export type RouteValue =
  | { readonly kind: 'home' }
  | { readonly kind: 'proc'; readonly path: readonly string[] }
  | { readonly kind: 'present'; readonly type: string; readonly text: string; readonly path: readonly string[] }
  | { readonly kind: 'ui'; readonly number: number }
  | { readonly kind: 'trace' }
  | { readonly kind: 'login' };

/* A canonical /proc entry name; the length is checked apart. */
const NAME = /^(?:[A-Za-z0-9_+,:=@.-]|%[0-9A-F]{2})+$/;
/* A presentation's TEXT in a URL: the erx: encoding of a canonical text. */
const ERX_URL_TEXT = /^(?:[A-Za-z0-9_+,:=@./-]|%25)+$/;
/* A UI's number: decimal, no leading zero. */
const NUMBER = /^(?:0|[1-9][0-9]{0,9})$/;
const U32_MAX = 0xffff_ffff;
/* The token without which no Route is made, so every Route passed the checks below. */
const MADE_HERE: unique symbol = Symbol('route');
const ascii = (text: string): Uint8Array => Uint8Array.from(text, (character) => character.charCodeAt(0));

export class Route {
  readonly #value: RouteValue;

  private constructor(token: typeof MADE_HERE, value: RouteValue) {
    if (token !== MADE_HERE) throw new TypeError('a Route is made only by its checks');
    this.#value = Object.freeze(value);
  }

  get value(): RouteValue {
    return this.#value;
  }

  /* Whether candidate is a Route made here, whatever its static type says. */
  static is(candidate: unknown): candidate is Route {
    return typeof candidate === 'object' && candidate !== null && #value in candidate;
  }

  static readonly #home = new Route(MADE_HERE, { kind: 'home' });
  static readonly #trace = new Route(MADE_HERE, { kind: 'trace' });
  static readonly #login = new Route(MADE_HERE, { kind: 'login' });

  static home(): Route {
    return Route.#home;
  }

  static trace(): Route {
    return Route.#trace;
  }

  static login(): Route {
    return Route.#login;
  }

  /* The view of an inspector path of entry names; none is the home route. */
  static path(names: readonly string[]): Route | undefined {
    if (names.length === 0) return Route.#home;
    if (names.length > WEB_PATH_SEGMENTS_MAX || !names.every(isLinkableName)) return undefined;
    return new Route(MADE_HERE, { kind: 'proc', path: Object.freeze([...names]) });
  }

  /*
   * The view of a presentation: a type the schema marks and a canonical
   * text whose parts are entry names that fill its marked path. A part . or
   * .. is no canonical name, and would be a dot segment in the URL.
   */
  static present(type: string, text: string): Route | undefined {
    if (text.length > WEB_PRINTED_MAX) return undefined;
    if (!text.split('/').every((part) => isName(part) && part !== '.' && part !== '..')) return undefined;
    const path = presentationPath(type, text);
    if (path === undefined) return undefined;
    return new Route(MADE_HERE, { kind: 'present', type, text, path: Object.freeze([...path]) });
  }

  static ui(number: number): Route | undefined {
    if (!Number.isInteger(number) || number < 0 || number > U32_MAX) return undefined;
    return new Route(MADE_HERE, { kind: 'ui', number });
  }
}

/* A canonical entry name within the wire's segment bound. */
const isName = (name: string): boolean => name.length <= WEB_SEGMENT_MAX && NAME.test(name);

/*
 * A canonical entry name that no URL parser takes for a dot segment. NAME
 * admits only upper-case hexadecimal, so %2E is the one spelling of an
 * encoded dot left to look for.
 */
function isLinkableName(name: string): boolean {
  if (!isName(name)) return false;
  const decoded = name.replaceAll('%2E', '.');
  return decoded !== '.' && decoded !== '..';
}

/*
 * The route a URL's path names, or undefined for a path that names
 * nothing. The path is as the browser's location gives it, percent-encoded;
 * the fixed routes come before /TYPE/TEXT, and no presentation type is
 * named after one of them (the generator refuses it).
 */
export function parseRoute(pathname: string): Route | undefined {
  if (pathname === '/') return Route.home();
  if (!pathname.startsWith('/')) return undefined;
  const [first, ...rest] = pathname.slice(1).split('/');
  switch (first) {
    case 'proc':
      return rest.length === 0 ? undefined : Route.path(rest);
    case 'ui':
      return rest.length === 1 && NUMBER.test(rest[0] as string) ? Route.ui(Number(rest[0])) : undefined;
    case 'trace':
      return rest.length === 0 ? Route.trace() : undefined;
    case 'login':
      return rest.length === 0 ? Route.login() : undefined;
    case 'ws':
      return undefined;
    default: {
      const text = rest.join('/');
      if (rest.length === 0 || !ERX_URL_TEXT.test(text)) return undefined;
      return Route.present(first as string, text.replaceAll('%25', '%'));
    }
  }
}

/* The one writer of a link: the path of the URL that names route. */
export function hrefOf(route: Route): string {
  if (!Route.is(route)) throw new TypeError('hrefOf writes a link only to a Route');
  const value = route.value;
  switch (value.kind) {
    case 'home':
      return '/';
    case 'proc':
      return `/proc/${value.path.join('/')}`;
    case 'present':
      return `/${value.type}/${erxText(ascii(value.text))}`;
    case 'ui':
      return `/ui/${value.number}`;
    case 'trace':
      return '/trace';
    case 'login':
      return '/login';
  }
}

/*
 * A name the machine sent, as text: its line escape, which is the name
 * itself when the bytes are a canonical name, since the escape keeps every
 * printable ASCII character. Anything else holds an escape token, whose "<"
 * no name holds, so the route's checks refuse it.
 */
const machineName = (text: MachineText): string => escapedText(text.runs());

/* The route of an inspector path the machine sent, entry names as texts. */
export function pathRoute(names: readonly MachineText[]): Route | undefined {
  return Route.path(names.map(machineName));
}

/* The route of a presentation the machine sent: its type's name and canonical text. */
export function presentRoute(type: MachineText, text: MachineText): Route | undefined {
  return Route.present(machineName(type), machineName(text));
}
