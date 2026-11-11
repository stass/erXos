/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's connection core (docs/design-web.md, "The client"): hello and
 * the views' opens on a new socket, one next per rendered update, ends and
 * byes passed to the page, and reconnection after 1 s doubling to 30 s with
 * every view marked stale meanwhile.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { type Action, type Input, type Reopenable, type State, RETRY_FIRST_MS, RETRY_MAX_MS, start, step } from '../src/connection.ts';
import { type Browser, type Machine, decodeBrowser, encodeMachine, machineText, protocolHash } from '../src/generated/proto.ts';
import { escapedText } from '../src/text.ts';

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);
const HOME: Reopenable = { tag: 'path', segments: [] };
const KERNEL: Reopenable = { tag: 'path', segments: [utf8('kernel')] };

function machine(message: Machine): Input {
  const encoded = encodeMachine(message);
  assert.ok(encoded.ok);
  return { kind: 'message', bytes: encoded.bytes };
}

/* The browser messages among actions, decoded, so a test reads what went out. */
function sent(actions: readonly Action[]): Browser[] {
  return actions.flatMap((action) => {
    if (action.kind !== 'send') return [];
    const decoded = decodeBrowser(action.bytes);
    assert.ok(decoded.ok);
    return [decoded.value];
  });
}

function run(state: State, ...inputs: Input[]): { state: State; actions: Action[] } {
  let actions: Action[] = [];
  for (const input of inputs) ({ state, actions } = step(state, input));
  return { state, actions };
}

const record = (view: number): Machine => ({
  tag: 'update',
  view,
  body: {
    tag: 'record',
    record: { path: [], kind: machineText(utf8('machine')), id: { tag: 'int', digits: 0n }, attrs: [],
              children: { completeness: 'complete', names: [] } },
  },
});

test('a new socket sends hello and opens each view in order', () => {
  const started = start([HOME, KERNEL]);
  assert.deepEqual(started.actions, [{ kind: 'connect' }]);
  const { actions } = step(started.state, { kind: 'opened' });
  assert.deepEqual(sent(actions), [
    { tag: 'hello', hash: protocolHash() },
    { tag: 'open', view: 1, target: HOME },
    { tag: 'open', view: 2, target: KERNEL },
  ]);
});

test('an update is shown, and its next goes out once it is rendered, once', () => {
  const opened = run(start([HOME, KERNEL]).state, { kind: 'opened' }).state;
  const shown = step(opened, machine(record(2)));
  assert.deepEqual(shown.actions.map((action) => [action.kind, 'index' in action ? action.index : -1]), [['show', 1]]);
  const rendered = step(shown.state, { kind: 'rendered', index: 1 });
  assert.deepEqual(sent(rendered.actions), [{ tag: 'next', view: 2 }]);
  assert.deepEqual(step(rendered.state, { kind: 'rendered', index: 1 }).actions, []);
  assert.deepEqual(step(rendered.state, { kind: 'rendered', index: 0 }).actions, []);
});

test('an update for a view never opened closes the socket', () => {
  const opened = run(start([HOME]).state, { kind: 'opened' }).state;
  assert.deepEqual(step(opened, machine(record(7))).actions, [{ kind: 'close' }]);
});

test('an ended view passes its reason on and is not asked again', () => {
  const opened = run(start([HOME]).state, { kind: 'opened' }).state;
  const ended = step(opened, machine({ tag: 'ended', view: 1, reason: machineText(utf8('scope')) }));
  const [action] = ended.actions;
  assert.ok(action !== undefined && action.kind === 'ended');
  assert.equal(action.index, 0);
  assert.equal(escapedText(action.reason.runs()), 'scope');
  assert.deepEqual(step(ended.state, { kind: 'rendered', index: 0 }).actions, []);
});

test('bytes that are no machine message close the socket', () => {
  const opened = run(start([HOME]).state, { kind: 'opened' }).state;
  assert.deepEqual(step(opened, { kind: 'message', bytes: Uint8Array.of(0xff) }).actions, [{ kind: 'close' }]);
});

test('a lost socket marks the views stale and retries after 1 s, doubling to 30 s', () => {
  let state = start([HOME]).state;
  const waits: number[] = [];
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const closed = step(state, { kind: 'closed' });
    assert.equal(closed.actions[0]?.kind, 'stale');
    const wait = closed.actions[1];
    assert.ok(wait !== undefined && wait.kind === 'wait');
    waits.push(wait.ms);
    const retried = step(closed.state, { kind: 'retry' });
    assert.deepEqual(retried.actions, [{ kind: 'connect' }]);
    state = retried.state;
  }
  assert.deepEqual(waits, [RETRY_FIRST_MS, 2000, 4000, 8000, 16000, RETRY_MAX_MS, RETRY_MAX_MS, RETRY_MAX_MS]);
});

test('a welcome resets the delay, and a reconnect reopens every view from 1', () => {
  const welcome = machine({ tag: 'welcome', principal: machineText(utf8('root')), build: machineText(utf8('b')) });
  const slow = run(start([HOME]).state, { kind: 'closed' }, { kind: 'retry' }, { kind: 'closed' }, { kind: 'retry' },
                   { kind: 'opened' }, machine(record(1)), welcome).state;
  const closed = step(slow, { kind: 'closed' });
  assert.deepEqual(closed.actions[1], { kind: 'wait', ms: RETRY_FIRST_MS });
  const reopened = run(closed.state, { kind: 'retry' }, { kind: 'opened' });
  assert.deepEqual(sent(reopened.actions).map((message) => message.tag === 'open' && message.view), [false, 1]);
});

test('a bye for another build ends the client; any other bye reconnects after the close', () => {
  const opened = run(start([HOME]).state, { kind: 'opened' }).state;
  const mismatch = step(opened, machine({ tag: 'bye', reason: 'mismatch' }));
  assert.deepEqual(mismatch.actions, [{ kind: 'bye', reason: 'mismatch' }, { kind: 'close' }]);
  assert.deepEqual(step(mismatch.state, { kind: 'closed' }).actions, [{ kind: 'stale' }]);
  const shutdown = step(opened, machine({ tag: 'bye', reason: 'shutdown' }));
  assert.deepEqual(shutdown.actions, [{ kind: 'bye', reason: 'shutdown' }]);
  assert.deepEqual(step(shutdown.state, { kind: 'closed' }).actions.map((action) => action.kind), ['stale', 'wait']);
});

test('input a phase does not expect changes nothing', () => {
  const connecting = start([HOME]).state;
  assert.deepEqual(step(connecting, machine(record(1))).actions, []);
  assert.deepEqual(step(connecting, { kind: 'retry' }).actions, []);
  assert.deepEqual(step(connecting, { kind: 'rendered', index: 0 }).actions, []);
});
