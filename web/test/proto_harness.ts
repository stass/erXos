/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TypeScript side of test/host/erx_web_proto_test.rb, over files of
 * "MESSAGE HEX" lines, MESSAGE browser or machine:
 *   node proto_harness.ts corpus OUT SEED COUNT  writes COUNT random messages;
 *   node proto_harness.ts reencode IN OUT        decodes each line of IN and writes
 *                                                "ok HEX" with the bytes the encoder
 *                                                writes back, or "refused REASON";
 *   node proto_harness.ts hash                   prints the protocol hash.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { PROTOCOL_HASH_HEX, decodeBrowser, decodeMachine } from '../src/generated/proto.ts';
import { MESSAGES, encodeAs, generator, randomMessage } from './proto_random.ts';
import type { MessageName } from './proto_random.ts';

const hex = (bytes: Uint8Array): string => Buffer.from(bytes).toString('hex').toUpperCase();

function reencode(line: string): string {
  const [name, digits] = line.split(' ');
  const message = MESSAGES.find((entry) => entry === name) as MessageName | undefined;
  if (message === undefined || digits === undefined) throw new Error(`bad line ${line}`);
  const bytes = Uint8Array.from(Buffer.from(digits, 'hex'));
  const decoded = message === 'browser' ? decodeBrowser(bytes) : decodeMachine(bytes);
  if (!decoded.ok) return `refused ${decoded.reason}`;
  const encoded = encodeAs(message, decoded.value);
  if (!encoded.ok) throw new Error(`accepted, then refused to encode: ${encoded.reason}`);
  return `ok ${hex(encoded.bytes)}`;
}

const [command, ...args] = process.argv.slice(2);
switch (command) {
  case 'corpus': {
    const [out, seed, count] = args;
    const below = generator(Number(seed));
    const lines = Array.from({ length: Number(count) }, () => randomMessage(below)).map(
      ({ message, bytes }) => `${message} ${hex(bytes)}\n`,
    );
    writeFileSync(out!, lines.join(''));
    break;
  }
  case 'reencode': {
    const [input, out] = args;
    const lines = readFileSync(input!, 'latin1').split('\n').filter((line) => line !== '');
    writeFileSync(out!, lines.map((line) => `${reencode(line)}\n`).join(''));
    break;
  }
  case 'hash':
    process.stdout.write(`${PROTOCOL_HASH_HEX}\n`);
    break;
  default:
    throw new Error(`unknown command ${command}`);
}
