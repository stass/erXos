/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The record view's rows (docs/design-web.md, "The client", Views): what the
 * page shows of one wire record, as parts the view renders, so the choices
 * are made here and tested without a DOM.
 *
 * A value whose status is not ok shows only its status's token, as
 * erx_render prints it (`[partial]`, `[unknown]`, `[unsupported]`,
 * `[timeout N]`, `[error]`), so no status reads as a value (W7). Every text
 * the machine sent stays a MachineText part, rendered only by Text (W2); the
 * client's own text is a plain part (brackets and separators) or a token.
 *
 * A child is a link to its own view: the record's path and the child's name,
 * /proc entry names the machine sent, read into a Route by pathRoute, which
 * the page writes with hrefOf, so a link's address passed the route's checks. A name
 * that makes no route, such as one that is not canonical, is text alone.
 */

import type { Attr, Children, Datum, Name, Path, Reporter, Status, WireRecord } from './generated/proto.ts';
import { type Route, pathRoute } from './routes.ts';

export type Part =
  | { readonly kind: 'text'; readonly text: Name }
  | { readonly kind: 'plain'; readonly text: string }
  | { readonly kind: 'token'; readonly text: string }
  | { readonly kind: 'present'; readonly type: Name; readonly text: Name }
  | { readonly kind: 'link'; readonly route: Route; readonly text: Name };

export type Row = { readonly key: Name; readonly value: readonly Part[]; readonly reporter: string };

export const recordRows = (record: WireRecord): Row[] =>
  record.attrs.map((attr: Attr) => ({ key: attr.key, value: valueParts(attr.status, attr.value), reporter: reporterLabel(attr.reporter) }));

/*
 * The children's names, each a link to its view where it makes a route, then
 * the token of a listing that is not complete. path is the record's own.
 */
export function childrenParts(path: Path, children: Children): Part[] {
  const above = entryNames(path);
  const names = children.names.flatMap((child, at) => [...(at === 0 ? [] : [plain(', ')]), ...childParts(above, child)]);
  switch (children.completeness) {
    case 'complete': return names;
    case 'partial': return [...names, ...(names.length > 0 ? [plain(' ')] : []), token('[partial]')];
    case 'unknown': return [token('[unknown]')];
  }
}

/* A child as a link below the path above it, or as its datum when it makes no route. */
function childParts(above: readonly Name[] | undefined, child: Datum): Part[] {
  if (above === undefined || child.tag !== 'text') return datumParts(child);
  const route = pathRoute([...above, child.bytes]);
  return route === undefined ? datumParts(child) : [{ kind: 'link', route, text: child.bytes }];
}

/* A path's entry names, which the machine sends as text data; undefined when one is not. */
function entryNames(path: Path): Name[] | undefined {
  const names = path.flatMap((datum) => (datum.tag === 'text' ? [datum.bytes] : []));
  return names.length === path.length ? names : undefined;
}

function valueParts(status: Status, value: Datum): Part[] {
  switch (status.tag) {
    case 'ok': return datumParts(value);
    case 'timeout': return [token(`[timeout ${status.ms}]`)];
    default: return [token(`[${status.tag}]`)];
  }
}

function datumParts(datum: Datum): Part[] {
  switch (datum.tag) {
    case 'int': return [plain(datum.digits.toString())];
    case 'text': return [{ kind: 'text', text: datum.bytes }];
    case 'atom': return [{ kind: 'text', text: datum.name }];
    case 'printed': return [{ kind: 'text', text: datum.text }];
    case 'present': return [{ kind: 'present', type: datum.type, text: datum.text }];
    case 'list': return [plain('['), ...joined(datum.items, ', '), plain(']')];
    case 'tuple': return [plain('{'), ...joined(datum.items, ', '), plain('}')];
  }
}

const joined = (items: readonly Datum[], separator: string): Part[] =>
  items.flatMap((item, at) => (at === 0 ? datumParts(item) : [plain(separator), ...datumParts(item)]));

const reporterLabel = (reporter: Reporter): string => (reporter.tag === 'stopgap' ? `stopgap ${reporter.name}` : reporter.tag);

const plain = (text: string): Part => ({ kind: 'plain', text });
const token = (text: string): Part => ({ kind: 'token', text });
