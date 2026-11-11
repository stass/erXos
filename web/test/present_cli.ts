/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The web client's side of test/host/web_present_test.rb's differential: each
 * line of standard input is a presentation's type, a space, and x and its
 * canonical text in hexadecimal; each line written is x and the hexadecimal
 * of the link the client writes, erx:TYPE/ and erxText of the text, a space,
 * and x and the hexadecimal of presentationPath's segments joined by "/", or
 * a lone - for a text that names nothing.
 */

import { readFileSync } from 'node:fs';
import { erxText, presentationPath } from '../src/names.ts';
import { hrefOf, presentRoute } from '../src/routes.ts';
import { MachineText } from '../src/text.ts';

const hex = (text: string): string => Buffer.from(text, 'latin1').toString('hex');
const lines = readFileSync(0, 'latin1').split('\n').filter((line) => line !== '');
const answers = lines.map((line) => {
  const [type = '', field = ''] = line.split(' ');
  const text = Buffer.from(field.slice(1), 'hex');
  const path = presentationPath(type, text.toString('latin1'));
  const route = presentRoute(new MachineText(Buffer.from(type, 'latin1')), new MachineText(Uint8Array.from(text)));
  const href = route === undefined ? '-' : `x${hex(hrefOf(route))}`;
  return `x${hex(`erx:${type}/${erxText(Uint8Array.from(text))}`)} ${path === undefined ? '-' : `x${hex(path.join('/'))}`} ${href}\n`;
});
process.stdout.write(answers.join(''));
