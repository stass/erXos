/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Random messages of the web protocol for proto.test.ts, proto_harness.ts
 * and proto_fuzz.ts: a random value of any web.txt type, built from TYPES,
 * the table the codec itself reads, so every case of every union is
 * reachable without a list of them here. The TypeScript twin of
 * test/erlang/erx_web_proto_tests.erl's random/2.
 */

import { STOPGAPS, TYPES, encodeBrowser, encodeMachine, machineText } from '../src/generated/proto.ts';
import type { Field, Spec } from '../src/generated/proto.ts';

export type Below = (bound: number) => number;

/* xorshift32: below(N) is uniform enough in 0..N-1 for N up to 2^32. */
export function generator(seed: number): Below {
  let state = (seed * 0x9e3779b9 + 1) >>> 0 || 1;
  return (bound) => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    return state % bound;
  };
}

/* Lists and sized values stay short so a message fits its bound, but reach their bound now and then. */
const SHORT = 4;
const AT_BOUND = 24;

function lengthUpto(max: number, below: Below): number {
  if (below(AT_BOUND) === 0 && max <= 4096) return max;
  return below(Math.min(max, SHORT) + 1);
}

function bytes(count: number, below: Below): Uint8Array {
  return Uint8Array.from({ length: count }, () => below(256));
}

function spec(name: string): Spec {
  if (name === 'boolean') return { form: 'boolean' };
  const found = TYPES.get(name);
  if (found === undefined) throw new Error(`no type ${name}`);
  return found;
}

function fields(list: readonly Field[], below: Below, level: number, value: Record<string, unknown>): Record<string, unknown> {
  for (const field of list) value[field.name] = random(field.type, below, level);
  return value;
}

/* A random value of type NAME at LEVEL of the depth union. */
export function random(name: string, below: Below, level = 1): unknown {
  const type = spec(name);
  switch (type.form) {
    case 'integer': {
      const pick = below(4);
      const value = pick === 0 ? type.min : pick === 1 ? type.max : type.min + below(type.max - type.min + 1);
      return value;
    }
    case 'boolean':
      return below(2) === 1;
    case 'bytes':
      return bytes(type.exact ? type.max : lengthUpto(type.max, below), below);
    case 'text':
      return machineText(bytes(lengthUpto(type.max, below), below));
    case 'digits': {
      const magnitude = BigInt(below(2 ** 32)) * BigInt(below(2 ** 32)) * BigInt(below(2 ** 32));
      return below(2) === 0 ? magnitude : -magnitude;
    }
    case 'stopgap':
      return STOPGAPS[below(STOPGAPS.length)];
    case 'ui_record': {
      const length = Math.max(1, lengthUpto(type.max, below));
      return Uint8Array.from([length & 0xff, (length >>> 8) & 0xff, (length >>> 16) & 0xff, length >>> 24, ...bytes(length, below)]);
    }
    case 'list':
      return Array.from({ length: below(Math.min(type.max, SHORT) + 1) }, () => random(type.element, below, level));
    case 'struct':
      return fields(type.fields, below, level, {});
    case 'union': {
      // A recursive case only below the depth, and seldom, so values stay small.
      const open = type.cases.filter((entry) => !entry.recursive || (level < type.depth && below(3) === 0));
      const entry = open[below(open.length)]!;
      if (type.enumeration) return entry.name;
      return fields(entry.fields, below, entry.recursive ? level + 1 : level, { tag: entry.name });
    }
  }
}

export const MESSAGES = ['browser', 'machine'] as const;
export type MessageName = (typeof MESSAGES)[number];

export function encodeAs(message: MessageName, value: unknown) {
  return message === 'browser' ? encodeBrowser(value as never) : encodeMachine(value as never);
}

/* A random message the encoder accepts, and its bytes. */
export function randomMessage(below: Below): { readonly message: MessageName; readonly bytes: Uint8Array } {
  for (;;) {
    const message = MESSAGES[below(MESSAGES.length)]!;
    const encoded = encodeAs(message, random(message, below));
    if (encoded.ok) return { message, bytes: encoded.bytes };
    if (!encoded.reason.startsWith('too_long')) throw new Error(`random ${message} refused: ${encoded.reason}`);
  }
}
