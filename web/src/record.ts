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
 */

import type { Attr, Children, Datum, Name, Reporter, Status, WireRecord } from './generated/proto.ts';

export type Part =
  | { readonly kind: 'text'; readonly text: Name }
  | { readonly kind: 'plain'; readonly text: string }
  | { readonly kind: 'token'; readonly text: string }
  | { readonly kind: 'present'; readonly type: Name; readonly text: Name };

export type Row = { readonly key: Name; readonly value: readonly Part[]; readonly reporter: string };

export const recordRows = (record: WireRecord): Row[] =>
  record.attrs.map((attr: Attr) => ({ key: attr.key, value: valueParts(attr.status, attr.value), reporter: reporterLabel(attr.reporter) }));

/* The children's names, then the token of a listing that is not complete. */
export function childrenParts(children: Children): Part[] {
  const names = joined(children.names, ', ');
  switch (children.completeness) {
    case 'complete': return names;
    case 'partial': return [...names, ...(names.length > 0 ? [plain(' ')] : []), token('[partial]')];
    case 'unknown': return [token('[unknown]')];
  }
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
