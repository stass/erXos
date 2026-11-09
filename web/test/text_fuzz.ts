/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The fuzz target of the web client's line escape (web/src/text.ts), whose
 * input is any text from the machine. Each round escapes random bytes, drawn
 * mostly from the bytes that start, continue or break UTF-8 sequences and the
 * unsafe classes' encodings, and checks that escapeLine returns and never
 * throws, that no plain run holds a character of the unsafe classes, a lone
 * surrogate or anything the input did not, and that the runs read back to the
 * input's bytes exactly: a byte token as its byte, a code point token and a
 * plain character as their UTF-8. So the escape is safe and loses nothing.
 *
 * Run as "node text_fuzz.ts SEED ROUNDS"; tools/fuzz/erx_web_text.rb runs it
 * for make check-fuzz, and text.test.ts for a short budget.
 */

import { BYTE_TOKEN, CODEPOINT_TOKEN, UNICODE_UNSAFE_RANGES } from '../src/generated/terminal_tables.ts';
import { escapeLine, type Run } from '../src/text.ts';

const INTERESTING = [
  0x00, 0x09, 0x0a, 0x1b, 0x3c, 0x5c, 0x7f, 0x80, 0x8f, 0x90, 0x9b, 0x9f, 0xa0, 0xad, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf,
  0xe0, 0xe2, 0xed, 0xef, 0xf0, 0xf3, 0xf4, 0xf5, 0xff,
];

/* A deterministic generator of 32-bit values (xorshift32). */
function generator(seed: number): () => number {
  let state = seed >>> 0 || 1;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return state >>> 0;
  };
}

function input(next: () => number): Uint8Array {
  const length = next() % 24;
  return Uint8Array.from({ length }, () => {
    const choice = next() % 4;
    if (choice === 0) return next() & 0xff;
    if (choice === 1) return 0x80 | (next() & 0x3f);
    return INTERESTING[next() % INTERESTING.length];
  });
}

const unsafe = (point: number): boolean => {
  for (let index = 0; index < UNICODE_UNSAFE_RANGES.length; index += 2) {
    if (point >= UNICODE_UNSAFE_RANGES[index] && point <= UNICODE_UNSAFE_RANGES[index + 1]) return true;
  }
  return false;
};

/* The bytes the runs stand for, or a reason they stand for none. */
function readBack(runs: readonly Run[]): number[] | string {
  const bytes: number[] = [];
  for (const run of runs) {
    if (run.kind === 'plain') {
      if (run.text === '') return 'an empty plain run';
      for (const character of run.text) {
        const point = character.codePointAt(0) ?? -1;
        if (point >= 0xd800 && point <= 0xdfff) return `a lone surrogate ${point.toString(16)}`;
        if (unsafe(point)) return `an unsafe character ${point.toString(16)} in plain text`;
      }
      bytes.push(...new TextEncoder().encode(run.text));
    } else if (run.text.startsWith(BYTE_TOKEN.prefix)) {
      bytes.push(Number.parseInt(run.text.slice(BYTE_TOKEN.prefix.length, -BYTE_TOKEN.suffix.length || undefined), 16));
    } else if (run.text.startsWith(CODEPOINT_TOKEN.prefix)) {
      const point = Number.parseInt(run.text.slice(CODEPOINT_TOKEN.prefix.length, -CODEPOINT_TOKEN.suffix.length || undefined), 16);
      if (!unsafe(point)) return `a token for the safe character ${point.toString(16)}`;
      bytes.push(...new TextEncoder().encode(String.fromCodePoint(point)));
    } else {
      return `a token of no kind: ${run.text}`;
    }
  }
  return bytes;
}

/* null when every round holds, otherwise the first failing input and why. */
export function fuzz(seed: number, rounds: number): string | null {
  const next = generator(seed);
  for (let round = 0; round < rounds; round += 1) {
    const bytes = input(next);
    const hex = Buffer.from(bytes).toString('hex');
    let back: number[] | string;
    try {
      back = readBack(escapeLine(bytes));
    } catch (error) {
      return `${hex}: escapeLine threw ${String(error)}`;
    }
    if (typeof back === 'string') return `${hex}: ${back}`;
    if (Buffer.from(back).toString('hex') !== hex) return `${hex}: the runs read back as ${Buffer.from(back).toString('hex')}`;
  }
  return null;
}

if (import.meta.main) {
  const [seed, rounds] = process.argv.slice(2).map(Number);
  const failure = fuzz(seed, rounds);
  if (failure !== null) {
    console.log(`fuzz: ${failure}`);
    process.exit(1);
  }
  console.log(`fuzz: ${rounds} rounds ok`);
}
