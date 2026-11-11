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
 * client's own text is a plain part (an integer's digits, brackets and
 * separators) or a status token, which carries its status as a lamp, so the
 * page can light it.
 *
 * The children are listed one group of parts per child, so a child is one
 * entry whatever its datum. A child is a link to its own view: the record's path and the child's name,
 * /proc entry names the machine sent, read into a Route by pathRoute, which
 * the page writes with hrefOf, so a link's address passed the route's checks. A name
 * that makes no route, such as one that is not canonical, is text alone.
 */

import type { Attr, Children, Datum, Name, Path, Reporter, Status, WireRecord } from './generated/proto.ts';
import { Route, pathRoute } from './routes.ts';
import type { MachineText } from './text.ts';

/* A status as the page lights it: every status a value or a listing can have. */
export type Lamp = Status['tag'];

export type Part =
  | { readonly kind: 'text'; readonly text: Name }
  | { readonly kind: 'plain'; readonly text: string }
  | { readonly kind: 'token'; readonly text: string; readonly lamp: Lamp }
  | { readonly kind: 'present'; readonly type: Name; readonly text: Name }
  | { readonly kind: 'link'; readonly route: Route; readonly text: Name };

export type Row = { readonly key: Name; readonly value: readonly Part[]; readonly reporter: string };

export const recordRows = (record: WireRecord): Row[] =>
  record.attrs.map((attr: Attr) => ({ key: attr.key, value: valueParts(attr.status, attr.value), reporter: reporterLabel(attr.reporter) }));

/*
 * The children as the page lists them: the parts of each named child, each a
 * link to its view where it makes a route, and the token of a listing that is
 * not complete. path is the record's own.
 */
export type Listing = { readonly names: readonly (readonly Part[])[]; readonly mark: Part | undefined };

export function childrenListing(path: Path, children: Children): Listing {
  const above = entryNames(path);
  const names = listed(children).map((child) => childParts(above, child));
  switch (children.completeness) {
    case 'complete': return { names, mark: undefined };
    case 'partial': return { names, mark: token('[partial]', 'partial') };
    case 'unknown': return { names, mark: token('[unknown]', 'unknown') };
  }
}

/* The children a listing names: none when the listing is unknown, whatever names it carries. */
const listed = (children: Children): readonly Datum[] => (children.completeness === 'unknown' ? [] : children.names);

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
    case 'timeout': return [token(`[timeout ${status.ms}]`, status.tag)];
    default: return [token(`[${status.tag}]`, status.tag)];
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
const token = (text: string, lamp: Lamp): Part => ({ kind: 'token', text, lamp });

/*
 * The front panel (docs/design-web.md, "The client", Views): one light per
 * attribute, lit by its status, and one per child the listing names
 * (none when it is unknown), lit because the machine named it. A light is changed when the record before
 * this one, prior, had no such attribute or child, or held the attribute
 * with another status or value, so the panel blinks only where the machine's
 * data moved. The first record has no prior and changes nothing.
 */
export type Light = { readonly lamp: Lamp; readonly changed: boolean };
export type Panel = { readonly attrs: readonly Light[]; readonly children: readonly Light[] };

export function frontPanel(record: WireRecord, prior: WireRecord | undefined): Panel {
  const before = prior === undefined ? undefined : new Map(prior.attrs.map((attr) => [textKey(attr.key), attrKey(attr)]));
  const named = prior === undefined ? undefined : new Set(listed(prior.children).map(datumKey));
  return {
    attrs: record.attrs.map((attr) => ({
      lamp: attr.status.tag,
      changed: before !== undefined && before.get(textKey(attr.key)) !== attrKey(attr),
    })),
    children: listed(record.children).map((child) => ({ lamp: 'ok', changed: named !== undefined && !named.has(datumKey(child)) })),
  };
}

/*
 * Keys that compare data, never shown: a text's key is its escape's runs,
 * plain and token apart, so two texts share a key only when their escapes
 * are the same runs. A value that is not ok is keyed by its status alone, as
 * it shows only its token.
 */
const textKey = (text: MachineText): string => JSON.stringify(text.runs());

const attrKey = (attr: Attr): string =>
  attr.status.tag === 'ok' ? `ok:${datumKey(attr.value)}` : JSON.stringify(attr.status);

function datumKey(datum: Datum): string {
  switch (datum.tag) {
    case 'int': return `int:${datum.digits}`;
    case 'text': return `text:${textKey(datum.bytes)}`;
    case 'atom': return `atom:${textKey(datum.name)}`;
    case 'printed': return `printed:${textKey(datum.text)}`;
    case 'present': return `present:${textKey(datum.type)}:${textKey(datum.text)}`;
    case 'list': return `list:[${datum.items.map(datumKey).join(',')}]`;
    case 'tuple': return `tuple:[${datum.items.map(datumKey).join(',')}]`;
  }
}

/*
 * The trail above a page, from the home route to the page's own: each
 * entry name of the route's path, the client's own ASCII text, with the
 * route of the path up to it.
 */
export type Crumb = { readonly name: string; readonly route: Route };

export const crumbs = (path: readonly string[]): Crumb[] =>
  path.flatMap((name, at) => {
    const route = Route.path(path.slice(0, at + 1));
    return route === undefined ? [] : [{ name, route }];
  });
