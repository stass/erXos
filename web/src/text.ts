/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Machine text in the web client (docs/design-web.md, "The client", rule
 * W2). Every text the machine sends is a MachineText, whose bytes no code
 * outside this module can read: the one thing a MachineText yields is its
 * line escape, runs of plain text and escape tokens, so whatever renders it
 * renders only escaped text.
 *
 * escapeLine is erx_text:escape_line/1's and Erx::LineEscape's twin
 * (docs/design-live.md, "Attributed text"). It decodes the bytes strictly as
 * UTF-8 by the Unicode Standard's table 3-7 (no overlong form, encoded
 * surrogate or code point past U+10FFFF), never with TextDecoder, whose
 * replacement character would hide an invalid byte. A byte that begins or
 * continues no well-formed sequence is a byte token, <0xC0>, and decoding
 * resumes at the next byte; a character of the unsafe classes of
 * abi/terminal.txt is a code point token, <U+202E>, tab and newline among
 * them. The classes and the tokens' texts are generated from the same source
 * as Erlang's and Ruby's.
 */

import { BYTE_TOKEN, CODEPOINT_TOKEN, UNICODE_UNSAFE_RANGES, type Token } from './generated/terminal_tables.ts';

/* A run of the escaped text: plain characters, or one escape token. */
export type Run = { readonly kind: 'plain' | 'token'; readonly text: string };

/* One unit of the input: a well-formed character, or a byte outside any. */
type Unit = { readonly point: number } | { readonly byte: number };

export class MachineText {
  readonly #bytes: Uint8Array;

  /* The text of bytes, copied, so a later write to the caller's buffer changes nothing. */
  constructor(bytes: Uint8Array) {
    this.#bytes = new Uint8Array(bytes);
  }

  /* The text's line escape, the only view of its bytes. */
  runs(): Run[] {
    return escapeLine(this.#bytes);
  }
}

/* The line escape of bytes, as runs; a plain run is never empty. */
export function escapeLine(bytes: Uint8Array): Run[] {
  const runs: Run[] = [];
  let plain = '';
  for (const unit of units(bytes)) {
    if ('point' in unit && !unsafe(unit.point)) {
      plain += String.fromCodePoint(unit.point);
      continue;
    }
    if (plain !== '') runs.push({ kind: 'plain', text: plain });
    plain = '';
    runs.push({ kind: 'token', text: 'byte' in unit ? render(unit.byte, BYTE_TOKEN) : render(unit.point, CODEPOINT_TOKEN) });
  }
  if (plain !== '') runs.push({ kind: 'plain', text: plain });
  return runs;
}

/* The escaped text as one string, as erx_text:escape_line/1 returns it. */
export const escapedText = (runs: readonly Run[]): string => runs.map((run) => run.text).join('');

/*
 * The units of bytes by table 3-7: the lead byte fixes the sequence's length
 * and the range its second byte must fall in; every later byte is 80..BF.
 */
function* units(bytes: Uint8Array): Generator<Unit> {
  let at = 0;
  while (at < bytes.length) {
    const shape = sequence(bytes[at]);
    const point = shape === null ? -1 : decode(bytes, at, shape);
    if (shape === null || point < 0) {
      yield { byte: bytes[at] };
      at += 1;
    } else {
      yield { point };
      at += shape.length;
    }
  }
}

/*
 * The code point of the sequence of shape at bytes[at], or -1 when a later
 * byte is out of its range or the input ends first.
 */
function decode(bytes: Uint8Array, at: number, shape: Shape): number {
  let point = bytes[at] & shape.mask;
  for (let index = 1; index < shape.length; index += 1) {
    const next = at + index < bytes.length ? bytes[at + index] : -1;
    const [low, high] = index === 1 ? shape.second : [0x80, 0xbf];
    if (next < low || next > high) return -1;
    point = (point << 6) | (next & 0x3f);
  }
  return point;
}

type Shape = { readonly length: number; readonly mask: number; readonly second: readonly [number, number] };

function sequence(lead: number): Shape | null {
  if (lead <= 0x7f) return { length: 1, mask: 0x7f, second: [0, 0] };
  if (lead >= 0xc2 && lead <= 0xdf) return { length: 2, mask: 0x1f, second: [0x80, 0xbf] };
  if (lead === 0xe0) return { length: 3, mask: 0x0f, second: [0xa0, 0xbf] };
  if (lead === 0xed) return { length: 3, mask: 0x0f, second: [0x80, 0x9f] };
  if (lead >= 0xe1 && lead <= 0xef) return { length: 3, mask: 0x0f, second: [0x80, 0xbf] };
  if (lead === 0xf0) return { length: 4, mask: 0x07, second: [0x90, 0xbf] };
  if (lead >= 0xf1 && lead <= 0xf3) return { length: 4, mask: 0x07, second: [0x80, 0xbf] };
  if (lead === 0xf4) return { length: 4, mask: 0x07, second: [0x80, 0x8f] };
  return null;
}

/* Binary search of the flat, sorted, disjoint ranges. */
function unsafe(point: number): boolean {
  let low = 0;
  let high = UNICODE_UNSAFE_RANGES.length / 2 - 1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (point < UNICODE_UNSAFE_RANGES[2 * middle]) high = middle - 1;
    else if (point > UNICODE_UNSAFE_RANGES[2 * middle + 1]) low = middle + 1;
    else return true;
  }
  return false;
}

function render(value: number, token: Token): string {
  return `${token.prefix}${value.toString(16).toUpperCase().padStart(token.minimum, '0')}${token.suffix}`;
}
