/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TypeScript side of test/host/erx_ui_wire_test.rb's parity test.
 *
 * Reads a stream of the widget server's records from standard input with the
 * generated read() and prints one line per record naming what it read, in
 * the format of erx_ui_wire_tests:corpus/3: kinds, properties and enum
 * members by name, texts in hex, and a status block before the value of each
 * status property. Exits 1 at a refused record, printing "refused at OFFSET:
 * REASON" as the C harness does, or at a stream that ends inside a record.
 *
 * With the argument "each", reads on past a refused record as the C harness
 * does: "refused: REASON" for it, then the record after the bytes its length
 * word counts, stopping at "refused: bad length" or at "more".
 *
 * With the arguments "write PATH SEED", writes the other way instead: random
 * event and pixels records, with the generated writer, to PATH, and one line
 * per record to standard output naming what it wrote, in the format of
 * erx_ui_wire_tests:read_corpus/2. Every event property is written, each
 * detail tag at its bounds and at random, and pixels from empty to the
 * longest.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import {
  EVENT_TEXT_MAX,
  PIXELS_DATA_MAX,
  PROPERTIES,
  REPORTERS,
  STATUSES,
  read,
  writeEvent,
  writePixels,
  type Detail,
  type Prop,
  type UIRecord,
  type Value,
} from '../src/generated/ui_wire.ts';

const hex = (bytes: Uint8Array): string => `x${Buffer.from(bytes).toString('hex')}`;

function valueText(prop: Prop, value: Value | null): string {
  if (value === null) return '-';
  switch (prop.form) {
    case 'list':
      return `[${(value as Uint8Array[]).map(hex).join(',')}]`;
    case 'presentation': {
      const { name, text } = value as { name: Uint8Array; text: Uint8Array };
      return `${hex(name)}:${hex(text)}`;
    }
    case 'text':
    case 'bytes':
      return hex(value as Uint8Array);
    default:
      return String(value);
  }
}

function propToken(prop: Prop): string {
  const block = PROPERTIES.get(prop.name)?.status
    ? `${STATUSES.indexOf(prop.status)},${REPORTERS.indexOf(prop.reporter)},${prop.stopgap},${prop.timeoutMs}:`
    : '';
  return `${prop.name}=${block}${valueText(prop, prop.value)}`;
}

function line(record: UIRecord): string {
  switch (record.tag) {
    case 'insert':
      return ['insert', record.node, record.parent, record.index, record.kind, ...record.props.map(propToken)].join(' ');
    case 'set':
      return ['set', record.node, ...record.props.map(propToken), '/', ...record.removed].join(' ');
    case 'remove':
      return `remove ${record.node}`;
    case 'move':
      return `move ${record.node} ${record.index}`;
    case 'commit':
    case 'repaint':
      return record.tag;
    case 'screen':
      return `screen ${record.width} ${record.height} ${record.chan}`;
    case 'input': {
      const input = record.input;
      if (input.form === 'pointer') return `pointer ${input.x} ${input.y} ${input.buttons}`;
      if (input.form === 'wheel') return `wheel ${input.steps}`;
      return `key ${input.down ? 'down' : 'up'} ${input.code} ${input.rune ?? 'none'}`;
    }
  }
}

function readStream(stream: Uint8Array, { each }: { each: boolean }): number {
  const lines: string[] = [];
  for (let offset = 0; offset < stream.length; ) {
    const result = read(stream.subarray(offset));
    if (each && result.result !== 'ok') {
      lines.push(result.result === 'more' ? 'more\n' : `refused: ${result.reason}\n`);
      if (result.result === 'more' || result.reason === 'bad length') break;
      offset += 4 + new DataView(stream.buffer, stream.byteOffset + offset, 4).getUint32(0, true);
      continue;
    }
    if (result.result !== 'ok') {
      process.stdout.write(lines.join(''));
      const message =
        result.result === 'bad' ? `refused at ${offset}: ${result.reason}` : `stream ends inside a record at ${offset}`;
      process.stderr.write(`${message}\n`);
      return 1;
    }
    lines.push(`${line(result.record)}\n`);
    offset += result.used;
  }
  process.stdout.write(lines.join(''));
  return 0;
}

/* xorshift32: the corpus is a function of the seed. */
function generator(seed: number): (bound: number) => number {
  let state = (seed * 0x9e3779b9 + 1) >>> 0 || 1;
  return (bound) => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    return state % bound;
  };
}

/* At most MAX bytes of valid UTF-8 of scalars of every encoded length. */
function randomUTF8(below: (bound: number) => number, max: number): Uint8Array {
  const ranges = [[0x20, 0x7e], [0x80, 0x7ff], [0x800, 0xffff], [0x10000, 0x10ffff]] as const;
  const out: number[] = [];
  for (;;) {
    const [low, high] = ranges[below(4)] as readonly [number, number];
    let point = low + below(high - low + 1);
    if (point >= 0xd800 && point <= 0xdfff) point = 0xfffd;
    const encoded = Buffer.from(String.fromCodePoint(point), 'utf8');
    if (encoded.length > max - out.length) return Uint8Array.from(out);
    out.push(...encoded);
  }
}

function detailText(detail: Detail): string {
  switch (detail.tag) {
    case 'none':
      return 'none';
    case 'text':
      return hex(detail.value);
    default:
      return String(detail.value);
  }
}

function writeCorpus(path: string, seed: number): number {
  const below = generator(seed);
  const events = [...PROPERTIES.values()].filter((type) => type.form === 'event').map((type) => type.name);
  const integers = [0, 1, -1, -(2 ** 31), 2 ** 31 - 1];
  const records: Uint8Array[] = [];
  const lines: string[] = [];
  for (let index = 0; index < 600; index++) {
    if (index % 3 === 2) {
      const length = index % 50 === 2 ? PIXELS_DATA_MAX : below(65);
      const [x, y, width, height] = [below(65536), below(65536), below(65536), below(65536)];
      const pixels = Uint8Array.from({ length }, () => below(256));
      records.push(writePixels(x, y, width, height, pixels) ?? fail('writer refused valid pixels'));
      lines.push(`pixels ${x} ${y} ${width} ${height} ${hex(pixels)}\n`);
      continue;
    }
    const node = index % 7 === 0 ? 0xffffffff : 1 + below(0xffffffff);
    const event = events[index % events.length] as string;
    const details: Detail[] = [
      { tag: 'none' },
      { tag: 'boolean', value: below(2) === 1 },
      { tag: 'integer', value: index % 5 === 0 ? (integers[below(5)] as number) : below(2 ** 32) | 0 },
      { tag: 'text', value: randomUTF8(below, index % 41 === 3 ? EVENT_TEXT_MAX : below(41)) },
    ];
    const detail = details[index % 4] as Detail;
    records.push(writeEvent(node, event, detail) ?? fail('writer refused a valid event'));
    lines.push(`event ${node} ${event} ${detailText(detail)}\n`);
  }
  writeFileSync(path, Buffer.concat(records));
  process.stdout.write(lines.join(''));
  return 0;
}

function fail(message: string): never {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

const [mode, path, seed] = process.argv.slice(2);
process.exitCode =
  mode === 'write' && path !== undefined
    ? writeCorpus(path, Number(seed))
    : readStream(readFileSync(0), { each: mode === 'each' });
