/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The machine's side of the browser tests (docs/design-web.md, 'Verification
 * and testing'). The page loads the built client from the host tool's own
 * front end, which test/host/web_browser_test.rb starts on loopback with the
 * client's files and nothing behind it, so every file arrives with the
 * headers the front end writes. The WebSocket never reaches that server:
 * Playwright's WebSocket routing hands it to a StandIn, which reads what the
 * client sends with the generated decoder and answers with the generated
 * encoder, as the machine's web domain would.
 *
 * The test fixture also keeps the page off the network: a request for
 * anything but the front end's origin is aborted and fails the test, and so
 * does an error the page throws.
 */

import { type Page, type WebSocketRoute, test as base, expect } from '@playwright/test';
import {
  type Browser,
  type Machine,
  type WireRecord,
  decodeBrowser,
  encodeMachine,
  machineText,
} from '../../src/generated/proto.ts';

export { expect };

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

/* Machine text of a JavaScript string's UTF-8 bytes, or of the bytes themselves. */
export const text = (value: string | Uint8Array) => machineText(typeof value === 'string' ? utf8(value) : value);

/*
 * The machine as the client sees it: it greets every connection, answers
 * each path view with record, and records every message the client sent.
 * A record view is pulled: the stand-in sends the record once per open and
 * then nothing, as the machine does while the record does not change.
 */
export class StandIn {
  /* Every message the client sent, decoded, over every connection, in order. */
  readonly heard: Browser[] = [];
  /* WebSockets the page opened to anything but the front end's /ws; any one fails the test. */
  readonly away: string[] = [];
  /* Messages that did not decode, as their reason; any one fails the test. */
  readonly refused: string[] = [];
  #record: WireRecord | undefined;
  #sockets: WebSocketRoute[] = [];
  #running = true;

  constructor(record?: WireRecord) {
    this.#record = record;
  }

  /* Takes every WebSocket the page opens; only the front end's /ws reaches the machine. */
  async attach(page: Page, origin: string): Promise<void> {
    await page.routeWebSocket(() => true, (socket) => {
      const url = new URL(socket.url());
      if (url.pathname === '/ws' && url.host === new URL(origin).host) {
        this.#accept(socket);
      } else {
        this.away.push(url.href);
        void socket.close({ code: 1008, reason: 'not the front end' });
      }
    });
  }

  /* The connections the client has made, counted by their hello. */
  connections(): number {
    return this.heard.filter((message) => message.tag === 'hello').length;
  }

  /* The machine stops: every connection drops, and a new one fails at once. */
  stop(): void {
    this.#running = false;
    this.drop();
  }

  /* Every connection drops, as when the host link breaks; new ones are taken. */
  drop(): void {
    for (const socket of this.#sockets) void socket.close({ code: 1001, reason: 'the machine went away' });
    this.#sockets = [];
  }

  #accept(socket: WebSocketRoute): void {
    if (!this.#running) {
      void socket.close({ code: 1011, reason: 'no machine' });
      return;
    }
    this.#sockets.push(socket);
    socket.onMessage((message) => {
      const bytes = typeof message === 'string' ? utf8(message) : new Uint8Array(message);
      const decoded = decodeBrowser(bytes);
      if (!decoded.ok) {
        this.refused.push(decoded.reason);
        return;
      }
      this.heard.push(decoded.value);
      this.#answer(socket, decoded.value);
    });
  }

  #answer(socket: WebSocketRoute, message: Browser): void {
    switch (message.tag) {
      case 'hello':
        send(socket, { tag: 'welcome', principal: text('root'), build: text('test') });
        break;
      case 'open':
        if (message.target.tag === 'path' && this.#record !== undefined) {
          send(socket, { tag: 'update', view: message.view, body: { tag: 'record', record: this.#record } });
        } else {
          send(socket, { tag: 'ended', view: message.view, reason: text('not served by the stand-in') });
        }
        break;
      case 'next':
      case 'close':
      case 'event':
        break;
    }
  }
}

function send(socket: WebSocketRoute, message: Machine): void {
  const encoded = encodeMachine(message);
  if (!encoded.ok) throw new Error(`the stand-in's ${message.tag} does not encode: ${encoded.reason}`);
  socket.send(Buffer.from(encoded.bytes));
}

/* A record of the machine with attrs and the given children. */
export function machineRecord(attrs: WireRecord['attrs'], children: WireRecord['children'] = { completeness: 'complete', names: [] },
                              kind = text('machine')): WireRecord {
  return { path: [], kind, id: { tag: 'int', digits: 0n }, attrs, children };
}

type Fixtures = { readonly machine: StandIn; readonly pageErrors: string[] };

/*
 * The test function of every browser test: a page whose WebSocket goes to a
 * StandIn serving the record a file names with test.use({ record }) (none by
 * default), which may reach no origin but the front end's, and whose
 * uncaught errors fail the test. Both fixtures are automatic, so a test that
 * names neither is still kept off the network.
 */
export const test = base.extend<Fixtures & { readonly record: WireRecord | undefined }>({
  record: [undefined, { option: true }],
  pageErrors: [async ({ page }, use) => {
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await use(errors);
    expect(errors, 'the page threw').toEqual([]);
  }, { auto: true }],
  machine: [async ({ page, record, baseURL }, use) => {
    const origin = new URL(baseURL as string).origin;
    const away: string[] = [];
    await page.context().route('**/*', (route) => {
      const url = new URL(route.request().url());
      if (url.origin === origin) return route.continue();
      away.push(url.href);
      return route.abort('blockedbyclient');
    });
    const machine = new StandIn(record);
    await machine.attach(page, origin);
    await use(machine);
    expect([...away, ...machine.away], 'the page reached past the front end').toEqual([]);
    expect(machine.refused, 'the client sent a message that does not decode').toEqual([]);
  }, { auto: true }],
});
