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
 * The page is laid out as an operator's console: a bezel with the path as a
 * trail of links and a status strip of the connection, a front panel of
 * lights (one per attribute, lit by its status, and one per child, each
 * blinking where the last update changed it), then the attributes' table and
 * the children as a grid of links. Every light shows only what the record
 * holds (W7), and each status token stays text beside its lamp.
 *
 * path holds a Route's entry names, canonical /proc names in ASCII, which the
 * open sends as its segments' bytes.
 */

import { Fragment, type ReactNode, useEffect, useState } from 'react';
import { type Reopenable, connect } from './connection.ts';
import type { ByeReason, Name, WireRecord } from './generated/proto.ts';
import { type Legend, type Light, type Listing, type Panel, type Part, type Scope, CHILDREN_SHOWN, childrenListing, crumbs, frontPanel, recordLegend, recordRows, recordScopes, shownChildren } from './record.ts';
import { Route, hrefOf } from './routes.ts';
import { Text } from './text.tsx';

/* A Route's names are ASCII, so their UTF-8 bytes are their ASCII bytes. */
const utf8 = new TextEncoder();

/*
 * What the page knows of its one view: the last record, the one before it,
 * how many have come, when the last came, and how the connection stands.
 */
type Seen = {
  readonly record?: WireRecord;
  readonly prior?: WireRecord;
  readonly updates: number;
  readonly at?: Date;
  readonly stale: boolean;
  readonly ended?: Name;
  readonly bye?: ByeReason;
};

export function RecordPage({ path }: { readonly path: readonly string[] }) {
  const [seen, setSeen] = useState<Seen>({ updates: 0, stale: false });
  const [rendered, setRendered] = useState<((index: number) => void) | undefined>(undefined);

  /* A page shows one path for its life: a link to another loads that one's page. */
  useEffect(() => {
    const target: Reopenable = { tag: 'path', segments: path.map((name) => utf8.encode(name)) };
    const report = connect([target], {
      show: (_index, body) => {
        if (body.tag !== 'record') return;
        setSeen((old) => ({
          record: body.record, prior: old.record, updates: old.updates + 1, at: new Date(),
          stale: false, ended: undefined, bye: undefined,
        }));
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

  const state = viewState(seen);
  return (
    <main className={`console console-${state}`}>
      <header className="bezel">
        <h1 className="wordmark">erXos</h1>
        <Trail path={path} />
        <Strip seen={seen} state={state} />
      </header>
      {seen.record !== undefined && <RecordView record={seen.record} prior={seen.prior} updates={seen.updates} />}
    </main>
  );
}

/*
 * The path of the page as the URL spells it, each step a link: the machine's
 * own record at /, then the /proc path down to the page. /proc alone names
 * nothing, so its step is text.
 */
function Trail({ path }: { readonly path: readonly string[] }) {
  const trail = crumbs(path);
  return (
    <nav className="trail" aria-label="path">
      <a href={hrefOf(Route.home())} aria-current={trail.length === 0 ? 'page' : undefined}>/</a>
      {trail.length > 0 && <span className="proc">proc</span>}
      {trail.map((crumb, at) => (
        <Fragment key={at}>
          <span className="slash">/</span>
          <a href={hrefOf(crumb.route)} aria-current={at === trail.length - 1 ? 'page' : undefined}>{crumb.name}</a>
        </Fragment>
      ))}
    </nav>
  );
}

/*
 * How the view stands, worst first: the machine closed the connection or
 * ended the view, the connection is lost and the record is stale, no record
 * has come yet, or the view is live. Anything but live drains the strip's
 * band and dims the panel and the table, so old data never looks current.
 */
type ViewState = 'down' | 'stale' | 'waiting' | 'live';

const viewState = (seen: Seen): ViewState =>
  seen.bye !== undefined || seen.ended !== undefined ? 'down'
    : seen.stale ? 'stale'
    : seen.record === undefined ? 'waiting'
    : 'live';

/*
 * The status strip: the state's words in a live region, which changes only
 * when the state does, and the time of the last update beside it, outside
 * the region, so a screen reader is not told of every update. Its lamp
 * flashes once for each update the page receives.
 */
function Strip({ seen, state }: { readonly seen: Seen; readonly state: ViewState }) {
  return (
    <div className={`strip strip-${state}`}>
      <span key={seen.updates} className="activity" aria-hidden="true" />
      <div className="state" role="status">
        {seen.bye !== undefined && <p className="notice">the machine closed the connection: {seen.bye}</p>}
        {seen.ended !== undefined && <p className="notice">view ended: <Text value={seen.ended} /></p>}
        {seen.stale && <p className="notice">{seen.at === undefined ? 'not connected' : 'stale since'}</p>}
        {state === 'waiting' && <p>waiting for the machine</p>}
        {state === 'live' && <p>live</p>}
      </div>
      {seen.at !== undefined && <p className="updated">{seen.stale ? '' : 'updated '}{seen.at.toLocaleTimeString()}</p>}
    </div>
  );
}

function RecordView({ record, prior, updates }: { readonly record: WireRecord; readonly prior?: WireRecord; readonly updates: number }) {
  const panel = frontPanel(record, prior);
  const listing = childrenListing(record.path, record.children);
  const legend = recordLegend(record);
  const scopes = recordScopes(record);
  return (
    <>
      {(panel.attrs.length > 0 || panel.children.length > 0) && <FrontPanel panel={panel} mark={listing.mark} updates={updates} />}
      <section className="record">
        <h2 className="kind"><Text value={record.kind} /></h2>
        {record.attrs.length > 0 && (
          <table className="attrs">
            <thead><tr><th>attribute</th><th>value</th><th>reporter</th></tr></thead>
            <tbody>
              {/* The rows and the panel's attribute lights both follow record.attrs, in order. */}
            {recordRows(record).map((row, at) => (
                <tr key={blinkKey(at, panel.attrs[at], updates)} className={panel.attrs[at]?.changed ? 'changed' : undefined}>
                  <td className="key"><Text value={row.key} /></td>
                  <td className="value">{parts(row.value)}</td>
                  <td className="reporter">{row.reporter}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {(legend.length > 0 || scopes.length > 0) && <Notes legend={legend} scopes={scopes} />}
        {(listing.names.length > 0 || listing.mark !== undefined) && <Children listing={listing} />}
      </section>
    </>
  );
}

/*
 * Below the table, what its unsupported and incomplete values mean and what
 * each stopgap reporter it names sees: the client's own words, and the
 * reporter's name, which the decoder admits only from the schema's generated
 * names (printable ASCII), so none of it passes through Text.
 */
function Notes({ legend, scopes }: { readonly legend: readonly Legend[]; readonly scopes: readonly Scope[] }) {
  return (
    <section className="notes" aria-label="notes on the values">
      {legend.map((entry, at) => (
        <p key={`legend-${at}`}>{parts([entry.token])}{entry.reporter !== undefined && <> {entry.reporter}</>}: {entry.meaning}</p>
      ))}
      {scopes.map((note) => <p key={note.reporter}>{note.reporter} ({note.label}): {note.scope}</p>)}
    </section>
  );
}

/*
 * The record's lights, a decoration of the table and the listing below it,
 * so assistive technology skips the lights and reads only their counts.
 */
function FrontPanel({ panel, mark, updates }: { readonly panel: Panel; readonly mark: Part | undefined; readonly updates: number }) {
  return (
    <section className="front-panel">
      {panel.attrs.length > 0 && <Bank lights={panel.attrs} label="attributes" updates={updates} />}
      {panel.children.length > 0 && <Bank lights={panel.children} label="children" mark={mark} updates={updates} />}
    </section>
  );
}

type BankProps = { readonly lights: readonly Light[]; readonly label: string; readonly mark?: Part; readonly updates: number };

/* A bank of lights and its count, with the listing's token when it is not complete. */
function Bank({ lights, label, mark, updates }: BankProps) {
  return (
    <div className={`bank bank-${label}`}>
      <div className="leds" aria-hidden="true">
        {lights.map((light, at) => (
          <span key={blinkKey(at, light, updates)} className={`led lamp-${light.lamp}${light.changed ? ' changed' : ''}`} />
        ))}
      </div>
      <p className="bank-label">{lights.length} {label}{mark !== undefined && <> {parts([mark])}</>}</p>
    </div>
  );
}

/*
 * The children, one cell each, then the listing's token when it is not
 * complete. A long listing shows its first CHILDREN_SHOWN cells and a button
 * for the rest; the choice is kept across updates while the grid stays on the page.
 */
function Children({ listing }: { readonly listing: Listing }) {
  const [all, setAll] = useState(false);
  const { cells, hidden } = shownChildren(listing, { all });
  return (
    <section className="children">
      <h3>children</h3>
      <ul className="listing">
        {cells.map((child, at) => <li key={at}>{parts(child)}</li>)}
        {listing.mark !== undefined && <li>{parts([listing.mark])}</li>}
      </ul>
      {hidden > 0 && (
        <button type="button" className="show-all" onClick={() => setAll(true)}>
          showing the first {CHILDREN_SHOWN}; show the other {hidden}
        </button>
      )}
    </section>
  );
}

/* A changed light's key is new with each update, so its blink starts again. */
const blinkKey = (at: number, light: Light | undefined, updates: number): string =>
  light?.changed ? `${at}:${updates}` : `${at}`;

function parts(list: readonly Part[]): ReactNode[] {
  return list.map((part, at) => {
    switch (part.kind) {
      case 'text': return <Text key={at} value={part.text} />;
      case 'plain': return part.text;
      case 'token': return <span key={at} className={`status-token lamp-${part.lamp}`}>{part.text}</span>;
      case 'present': return <Text key={at} value={part.text} />;
      case 'link': return <a key={at} href={hrefOf(part.route)}><Text value={part.text} /></a>;
    }
  });
}
