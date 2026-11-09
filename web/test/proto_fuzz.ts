/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The mutation fuzzer of the web client's protocol decoder,
 * web/src/generated/proto.ts (docs/design-web.md, "Verification and
 * testing"). Each round decodes random bytes, a random message, or one
 * mutated by flips, insertions, deletions and splices, as either message
 * union. Nothing may escape the decoder but its refusal, and every message
 * it accepts must encode back to the bytes it came from: the encoder refuses
 * whatever passes a bound, so an accepted message within its bounds is what
 * that shows. Run as "node proto_fuzz.ts SEED ROUNDS";
 * tools/fuzz/erx_web_proto_ts.rb runs it for the fuzz budget.
 */

import { decodeBrowser, decodeMachine } from '../src/generated/proto.ts';
import { MESSAGES, encodeAs, generator, randomMessage } from './proto_random.ts';
import type { Below, MessageName } from './proto_random.ts';

function mutate(seed: Uint8Array, below: Below): Uint8Array {
  const bytes = [...seed];
  for (let count = 1 + below(4); count > 0; count--) {
    const at = below(bytes.length + 1);
    switch (below(4)) {
      case 0:
        bytes[at] = below(256);
        break;
      case 1:
        bytes.splice(at, 0, below(256));
        break;
      case 2:
        bytes.splice(at, 1 + below(8));
        break;
      default:
        // A length or count word set near a bound or past the bytes.
        bytes.splice(at, 4, ...[below(256), below(4), below(2), 0]);
    }
  }
  return Uint8Array.from(bytes);
}

/* What is wrong with decoding INPUT as MESSAGE, or null. */
function check(message: MessageName, input: Uint8Array): string | null {
  const decoded = message === 'browser' ? decodeBrowser(input) : decodeMachine(input);
  if (!decoded.ok) return typeof decoded.reason === 'string' ? null : 'a refusal without a reason';
  const encoded = encodeAs(message, decoded.value);
  if (!encoded.ok) return `accepted, then refused to encode: ${encoded.reason}`;
  if (Buffer.compare(encoded.bytes, input) !== 0) return 'accepted, then encoded to other bytes';
  return null;
}

/* Run ROUNDS rounds from SEED; the first failure as a message, or null. */
export function fuzz(seed: number, rounds: number): string | null {
  const below = generator(seed);
  for (let round = 0; round < rounds; round++) {
    const base = randomMessage(below);
    const choice = below(4);
    const input =
      choice === 0 ? Uint8Array.from({ length: below(64) }, () => below(256)) : choice === 1 ? base.bytes : mutate(base.bytes, below);
    const message = choice === 1 || below(4) !== 0 ? base.message : MESSAGES[below(MESSAGES.length)]!;
    let problem: string | null;
    try {
      problem = check(message, input);
    } catch (error) {
      problem = `threw ${String(error)}`;
    }
    if (problem !== null) return `round ${round}: ${problem} on ${message} ${Buffer.from(input).toString('hex')}`;
  }
  return null;
}

if (import.meta.main) {
  const [seed, rounds] = process.argv.slice(2).map(Number);
  const problem = fuzz(seed ?? 1, rounds ?? 100_000);
  process.stdout.write(problem === null ? `fuzz: ${rounds} rounds ok\n` : `fuzz: ${problem}\n`);
  process.exitCode = problem === null ? 0 : 1;
}
