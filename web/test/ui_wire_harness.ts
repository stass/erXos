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
 * word counts, stopping at "refused: bad length" or at "more". With the
 * argument "rewrite", also writes each record it read with the generated
 * writeRecord() and exits 1 unless the bytes are those it read.
 *
 * With the arguments "write PATH SEED", writes the other way instead: random
 * event and pixels records, with the generated writer, to PATH, and one line
 * per record to standard output naming what it wrote, in the format of
 * erx_ui_wire_tests:read_corpus/2. Every event property is written, each
 * detail tag at its bounds and at random, and pixels from empty to the
 * longest; the generated readReport() must read each back as written.
 *
 * Texts come out of read() as MachineText, whose one view is its line
 * escape; bytesOf() takes the escape's runs back to the bytes, so the
 * harness prints the bytes the reader read without reaching past that view.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { BYTE_TOKEN, CODEPOINT_TOKEN, type Token } from '../src/generated/terminal_tables.ts';
import {
  EVENT_TEXT_MAX,
  PIXELS_DATA_MAX,
  PROPERTIES,
  REPORTERS,
  STATUSES,
  read,
  readReport,
  writeEvent,
  writePixels,
  writeRecord,
  type Detail,
  type Prop,
  type Report,
  type UIRecord,
} from '../src/generated/ui_wire.ts';
import type { MachineText } from '../src/text.ts';

const hex = (bytes: Uint8Array): string => `x${Buffer.from(bytes).toString('hex')}`;

/* The number a token of TOKEN's shape names, or null for a run of another shape. */
function tokenValue(text: string, token: Token): number | null {
  if (!text.startsWith(token.prefix) || !text.endsWith(token.suffix)) return null;
  return Number.parseInt(text.slice(token.prefix.length, text.length - token.suffix.length), 16);
}

/* The bytes whose line escape TEXT's runs are: plain text as UTF-8, each token as what it names. */
function bytesOf(text: MachineText): Uint8Array {
  const parts = text.runs().map((run) => {
    if (run.kind === 'plain') return Buffer.from(run.text, 'utf8');
    const byte = tokenValue(run.text, BYTE_TOKEN);
    if (byte !== null) return Uint8Array.of(byte);
    const point = tokenValue(run.text, CODEPOINT_TOKEN) ?? fail(`not a token: ${run.text}`);
    return Buffer.from(String.fromCodePoint(point), 'utf8');
  });
  return Uint8Array.from(Buffer.concat(parts));
}

/* A property read, with its texts as bytes. */
function withBytes(prop: Prop): Prop<Uint8Array> {
  switch (prop.form) {
    case 'text':
      return { ...prop, value: prop.value && bytesOf(prop.value) };
    case 'list':
      return { ...prop, value: prop.value && prop.value.map(bytesOf) };
    case 'presentation':
      return { ...prop, value: prop.value && { name: bytesOf(prop.value.name), text: bytesOf(prop.value.text) } };
    default:
      return prop;
  }
}

function recordWithBytes(record: UIRecord): UIRecord<Uint8Array> {
  switch (record.tag) {
    case 'insert':
    case 'set':
      return { ...record, props: record.props.map(withBytes) };
    default:
      return record;
  }
}

function valueText(prop: Prop<Uint8Array>): string {
  if (prop.value === null) return '-';
  switch (prop.form) {
    case 'list':
      return `[${prop.value.map(hex).join(',')}]`;
    case 'presentation':
      return `${hex(prop.value.name)}:${hex(prop.value.text)}`;
    case 'text':
    case 'bytes':
      return hex(prop.value);
    default:
      return String(prop.value);
  }
}

function propToken(prop: Prop<Uint8Array>): string {
  const block = PROPERTIES.get(prop.name)?.status
    ? `${STATUSES.indexOf(prop.status)},${REPORTERS.indexOf(prop.reporter)},${prop.stopgap},${prop.timeoutMs}:`
    : '';
  return `${prop.name}=${block}${valueText(prop)}`;
}

function line(record: UIRecord<Uint8Array>): string {
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

function readStream(stream: Uint8Array, { each, rewrite }: { each: boolean; rewrite: boolean }): number {
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
    const record = recordWithBytes(result.record);
    const original = stream.subarray(offset, offset + result.used);
    if (rewrite && !Buffer.from(writeRecord(record) ?? []).equals(original)) fail(`rewrote the record at ${offset} otherwise`);
    lines.push(`${line(record)}\n`);
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

function reportLine(report: Report): string {
  if (report.tag === 'event') return `event ${report.node} ${report.event} ${detailText(report.detail)}\n`;
  return `pixels ${report.x} ${report.y} ${report.width} ${report.height} ${hex(report.pixels)}\n`;
}

/* The lines readReport() reads from STREAM, which it must read whole. */
function readReports(stream: Uint8Array): string[] {
  const lines: string[] = [];
  for (let offset = 0; offset < stream.length; ) {
    const result = readReport(stream.subarray(offset));
    if (result.result !== 'ok') fail(`readReport ${result.result === 'bad' ? result.reason : 'more'} at ${offset}`);
    lines.push(reportLine(result.report));
    offset += result.used;
  }
  return lines;
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
    : readStream(readFileSync(0), { each: mode === 'each', rewrite: mode === 'rewrite' });
