/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The web client's protocol codec, web/src/generated/proto.ts, on its own:
 * a short fuzz run, and the shapes the client relies on. The agreement with
 * the Erlang codec, byte for byte and bound for bound, is
 * test/host/erx_web_proto_test.rb's.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MachineText, escapedText } from '../src/text.ts';
import { decodeMachine, encodeBrowser, encodeMachine, machineText, protocolHash } from '../src/generated/proto.ts';
import { fuzz } from './proto_fuzz.ts';

test('a short fuzz run finds nothing', () => {
  assert.equal(fuzz(7, 3000), null);
});

test('machine texts decode opaque and integers as bigints', () => {
  const name = machineText(Uint8Array.of(0x1b, 0x5b, 0xc0));
  const encoded = encodeMachine({
    tag: 'update',
    view: 3,
    body: {
      tag: 'record',
      record: {
        path: [{ tag: 'int', digits: -12345678901234567890n }],
        kind: name,
        id: { tag: 'atom', name },
        attrs: [],
        children: { completeness: 'partial', names: [] },
      },
    },
  });
  assert.ok(encoded.ok);
  const decoded = decodeMachine(encoded.bytes);
  assert.ok(decoded.ok);
  assert.equal(decoded.value.tag, 'update');
  const body = decoded.value.tag === 'update' ? decoded.value.body : undefined;
  assert.equal(body?.tag, 'record');
  if (body?.tag !== 'record') return;
  assert.ok(body.record.kind instanceof MachineText);
  assert.equal(escapedText(body.record.kind.runs()), '<U+001B>[<0xC0>');
  assert.deepEqual(body.record.path, [{ tag: 'int', digits: -12345678901234567890n }]);
});

test('a MachineText the codec did not make is refused', () => {
  const encoded = encodeMachine({ tag: 'ended', view: 1, reason: new MachineText(Uint8Array.of(0x61)) });
  assert.deepEqual(encoded, { ok: false, reason: 'bad_term name' });
});

test('hello carries exactly the 32-byte hash', () => {
  assert.equal(protocolHash().length, 32);
  assert.ok(encodeBrowser({ tag: 'hello', hash: protocolHash() }).ok);
  assert.equal(encodeBrowser({ tag: 'hello', hash: protocolHash().subarray(1) }).ok, false);
});
