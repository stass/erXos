/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The fuzz target of the web client's generated reader of ui.txt's binary
 * form (web/src/generated/ui_wire.ts), whose input comes from the machine.
 * Each round hands read() random bytes, a seed record or a seed record with
 * a few bytes changed, cut or added, and checks that read() returns and never
 * throws: a record whose size is what its length word says, a request for
 * more only when the buffer holds less than that, or a refusal with a reason.
 *
 * Run as "node ui_wire_fuzz.ts SEED ROUNDS"; tools/fuzz/erx_ui_wire_ts.rb
 * runs it for make check-fuzz, and ui_wire.test.ts for a short budget.
 */

import { KINDS, OP_MAX, PROPERTIES, read } from '../src/generated/ui_wire.ts';

const le = (value: number, bytes: number): number[] =>
  Array.from({ length: bytes }, (_, index) => Math.floor(value / 2 ** (8 * index)) & 0xff);
const record = (body: number[]): Uint8Array => Uint8Array.from([...le(body.length, 4), ...body]);
const text = (bytes: number[]): number[] => [...le(bytes.length, 4), ...bytes];
const number = (name: string): number => PROPERTIES.get(name)?.number ?? 0;

/*
 * Valid records: an insert of each kind with a status text and a boolean, a
 * set with removals, a move, a commit, a screen and each input form.
 */
export const SEEDS: readonly Uint8Array[] = [
  ...[...KINDS.values()].map((kind) =>
    record([1, ...le(5, 4), ...le(0, 4), 0, 0, kind, 2, number('text'), 0, 0, 0, ...le(0, 4), ...text([0x68, 0xc3, 0xa9]), number('visible'), 1]),
  ),
  record([3, ...le(5, 4), 1, number('visible'), 1, 2, number('text'), number('placeholder')]),
  record([4, ...le(5, 4), 1, 0]),
  record([5]),
  record([7, 128, 2, 224, 1, ...le(0x68081828, 4)]),
  record([8, 1, 10, 0, 20, 0, 1]),
  record([8, 2, 1, 30, 0, ...le(0x41, 4)]),
  record([8, 3, 0xff]),
];

/* xorshift32. */
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

function mutate(seed: Uint8Array, below: (bound: number) => number): Uint8Array {
  const bytes = [...seed];
  for (let count = 1 + below(4); count > 0; count--) {
    const at = below(bytes.length + 1);
    switch (below(4)) {
      case 0:
        bytes[at] = below(256);
        break;
      case 1:
        bytes.splice(at, 1);
        break;
      case 2:
        bytes.splice(at, 0, below(256));
        break;
      default:
        bytes.length = Math.min(bytes.length, at);
    }
  }
  return Uint8Array.from(bytes, (byte) => byte ?? 0);
}

/* One input's check; a message saying what is wrong, or null. */
function check(input: Uint8Array): string | null {
  const result = read(input);
  const size = input.length >= 4 ? new DataView(input.buffer, input.byteOffset).getUint32(0, true) : -1;
  switch (result.result) {
    case 'ok':
      return result.used === size + 4 && size <= OP_MAX ? null : `used ${result.used} for a length word of ${size}`;
    case 'more':
      return input.length < 4 || input.length < size + 4 ? null : 'asked for more of a whole record';
    case 'bad':
      return result.reason.length > 0 ? null : 'refused with no reason';
  }
}

/* Run ROUNDS rounds from SEED; the first failure as a message, or null. */
export function fuzz(seed: number, rounds: number): string | null {
  const below = generator(seed);
  for (let round = 0; round < rounds; round++) {
    const base = SEEDS[below(SEEDS.length)] as Uint8Array;
    const choice = below(4);
    const input =
      choice === 0 ? Uint8Array.from({ length: below(64) }, () => below(256)) : choice === 1 ? base : mutate(base, below);
    let problem: string | null;
    try {
      problem = check(input);
    } catch (error) {
      problem = `threw ${String(error)}`;
    }
    if (problem !== null) return `round ${round}: ${problem} on ${Buffer.from(input).toString('hex')}`;
  }
  return null;
}

if (import.meta.main) {
  const [seed, rounds] = process.argv.slice(2).map(Number);
  const problem = fuzz(seed ?? 1, rounds ?? 100_000);
  process.stdout.write(problem === null ? `fuzz: ${rounds} rounds ok\n` : `fuzz: ${problem}\n`);
  process.exitCode = problem === null ? 0 : 1;
}
