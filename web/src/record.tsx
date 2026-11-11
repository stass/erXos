/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A record's page (docs/design-web.md, "The client", Views): the record view
 * of one inspector path, kept current over the connection; the path of no
 * segment, the machine's own record, is the home page. The page shows the
 * last update it received, "stale since" its time while the connection is
 * lost (W7), why the machine ended the view, and why the machine said
 * goodbye. The record's children are links to their own pages.
 *
 * path holds a Route's entry names, canonical /proc names in ASCII, which the
 * open sends as its segments' bytes.
 */

import { type ReactNode, useEffect, useState } from 'react';
import { type Reopenable, connect } from './connection.ts';
import type { ByeReason, Name, WireRecord } from './generated/proto.ts';
import { type Part, childrenParts, recordRows } from './record.ts';
import { hrefOf } from './routes.ts';
import { Text } from './text.tsx';

/* A Route's names are ASCII, so their UTF-8 bytes are their ASCII bytes. */
const utf8 = new TextEncoder();

/* What the page knows of its one view: the last record and when it came. */
type Seen = {
  readonly record?: WireRecord;
  readonly at?: Date;
  readonly stale: boolean;
  readonly ended?: Name;
  readonly bye?: ByeReason;
};

export function RecordPage({ path }: { readonly path: readonly string[] }) {
  const [seen, setSeen] = useState<Seen>({ stale: false });
  const [rendered, setRendered] = useState<((index: number) => void) | undefined>(undefined);

  /* A page shows one path for its life: a link to another loads that one's page. */
  useEffect(() => {
    const target: Reopenable = { tag: 'path', segments: path.map((name) => utf8.encode(name)) };
    const report = connect([target], {
      show: (_index, body) => {
        if (body.tag === 'record') setSeen((old) => ({ ...old, record: body.record, at: new Date(), stale: false, ended: undefined, bye: undefined }));
      },
      ended: (_index, reason) => setSeen((old) => ({ ...old, ended: reason })),
      stale: () => setSeen((old) => ({ ...old, stale: true })),
      bye: (reason) => setSeen((old) => ({ ...old, bye: reason })),
    });
    setRendered(() => report);
  }, []);

  /*
   * Each update is asked for only once the one before it is on the screen: at
   * is new for each update, so this runs once per rendered update.
   */
  useEffect(() => {
    if (seen.at !== undefined) rendered?.(0);
  }, [seen.at, rendered]);

  return (
    <main>
      <h1>erXos</h1>
      {seen.bye !== undefined && <p className="notice">the machine closed the connection: {seen.bye}</p>}
      {seen.stale && <p className="notice">{seen.at === undefined ? 'not connected' : `stale since ${seen.at.toLocaleTimeString()}`}</p>}
      {seen.ended !== undefined && <p className="notice">view ended: <Text value={seen.ended} /></p>}
      {seen.record === undefined ? <p>waiting for the machine</p> : <RecordView record={seen.record} />}
    </main>
  );
}

function RecordView({ record }: { readonly record: WireRecord }) {
  const children = childrenParts(record.path, record.children);
  return (
    <section>
      <h2><Text value={record.kind} /></h2>
      <table className="record">
        <thead><tr><th>attribute</th><th>value</th><th>reporter</th></tr></thead>
        <tbody>
          {recordRows(record).map((row, at) => (
            <tr key={at}><td><Text value={row.key} /></td><td>{parts(row.value)}</td><td>{row.reporter}</td></tr>
          ))}
        </tbody>
      </table>
      {children.length > 0 && <p>children: {parts(children)}</p>}
    </section>
  );
}

function parts(list: readonly Part[]): ReactNode[] {
  return list.map((part, at) => {
    switch (part.kind) {
      case 'text': return <Text key={at} value={part.text} />;
      case 'plain': return part.text;
      case 'token': return <span key={at} className="token">{part.text}</span>;
      case 'present': return <Text key={at} value={part.text} />;
      case 'link': return <a key={at} href={hrefOf(part.route)}><Text value={part.text} /></a>;
    }
  });
}
