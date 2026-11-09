/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The web client's line escape and percent encodings (docs/design-web.md,
 * "The client" and "URLs") over the attributed-text corpus; the three-way
 * differential against Erlang and Ruby is test/host/web_text_test.rb.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { erxText, procName } from '../src/names.ts';
import { MachineText, escapeLine, escapedText } from '../src/text.ts';
import { fuzz } from './text_fuzz.ts';

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

test('the attributed-text corpus escapes to text and tokens', () => {
  const corpus: [Uint8Array, string][] = [
    [utf8('<script>&amp;'), '<script>&amp;'],
    [utf8('a\u202eb\u200bc'), 'a<U+202E>b<U+200B>c'],
    [utf8('\u009b1m'), '<U+009B>1m'],
    [utf8('t\tn\n'), 't<U+0009>n<U+000A>'],
    [Uint8Array.of(0x61, 0xc0, 0xaf, 0x62), 'a<0xC0><0xAF>b'],
    [Uint8Array.of(0xed, 0xa0, 0x80), '<0xED><0xA0><0x80>'],
    [Uint8Array.of(0xf4, 0x90, 0x80, 0x80), '<0xF4><0x90><0x80><0x80>'],
    [Uint8Array.of(0xe2, 0x82), '<0xE2><0x82>'],
    [utf8('\u{e0001}\ufeff\u00e9\u{1f600}'), '<U+E0001><U+FEFF>\u00e9\u{1f600}'],
  ];
  for (const [bytes, expected] of corpus) assert.equal(escapedText(escapeLine(bytes)), expected);
  assert.deepEqual(escapeLine(utf8('a\u202eb')), [
    { kind: 'plain', text: 'a' },
    { kind: 'token', text: '<U+202E>' },
    { kind: 'plain', text: 'b' },
  ]);
  assert.deepEqual(escapeLine(new Uint8Array(0)), []);
});

test('a machine text yields only its escape and keeps its own copy', () => {
  const bytes = utf8('x\u202e');
  const text = new MachineText(bytes);
  bytes[0] = 0x1b;
  assert.equal(escapedText(text.runs()), 'x<U+202E>');
  assert.deepEqual(Object.keys(text), []);
});

test('the percent encodings keep only their own bytes', () => {
  const all = Uint8Array.from({ length: 256 }, (_, byte) => byte);
  const kept = (text: string): string => text.replace(/%[0-9A-F]{2}/g, '');
  assert.equal(kept(procName(all)), '+,-0123456789:=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz');
  assert.equal(kept(erxText(all)), '+,-./0123456789:=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz');
  assert.equal(procName(utf8('..')), '%2E%2E');
  assert.equal(erxText(utf8('a b/\u00e9')), 'a%20b/%C3%A9');
});

test('the escape survives a short fuzz run', () => {
  assert.equal(fuzz(1, 20_000), null);
});
