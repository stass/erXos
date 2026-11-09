/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The web client's side of test/host/web_text_test.rb's differential: each
 * line of standard input is x and an input's bytes in hexadecimal; each line
 * written is x and the hexadecimal of its line escape, a space, and x and the
 * hexadecimal of its /proc entry name.
 */

import { readFileSync } from 'node:fs';
import { procName } from '../src/names.ts';
import { escapeLine, escapedText } from '../src/text.ts';

const hex = (text: string): string => Buffer.from(text, 'utf8').toString('hex');
const lines = readFileSync(0, 'latin1').split('\n').filter((line) => line.startsWith('x'));
const answers = lines.map((line) => {
  const bytes = Uint8Array.from(Buffer.from(line.slice(1), 'hex'));
  return `x${hex(escapedText(escapeLine(bytes)))} x${hex(procName(bytes))}\n`;
});
process.stdout.write(answers.join(''));
