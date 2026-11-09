/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's two percent encodings (docs/design-web.md, "URLs"). procName
 * is a /proc entry name, erx_procfs_core:name/1's encoding of a text
 * segment: every byte outside A-Z a-z 0-9 _ + , : = @ - is % and two
 * upper-case hexadecimal digits, so no name is . or .. or holds /, and no
 * name starts with . (docs/design-live.md, "The /proc tree"). erxText is a
 * presentation's text in the erx: URI encoding, the same with . and / kept
 * (docs/design-display.md, "Presentations"). Both are ASCII and hold no
 * control character, whatever the bytes. presentationPath is the /proc path
 * a presentation's canonical text names, from the inspection schema's
 * present marks (web/src/generated/present.ts), as erx_present:path/2 has it.
 */

import { PRESENTATIONS } from './generated/present.ts';

const PROC_KEPT = /[A-Za-z0-9_+,:=@-]/;
const ERX_KEPT = /[A-Za-z0-9_+,:=@./-]/;

function percent(bytes: Uint8Array, kept: RegExp): string {
  let text = '';
  for (const byte of bytes) {
    const character = String.fromCharCode(byte);
    text += byte < 0x80 && kept.test(character) ? character : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return text;
}

/* The /proc entry name of a text segment's bytes. */
export const procName = (bytes: Uint8Array): string => percent(bytes, PROC_KEPT);

/* A presentation's canonical text in the erx: URI encoding. */
export const erxText = (bytes: Uint8Array): string => percent(bytes, ERX_KEPT);

/*
 * The /proc path a presentation's canonical text names: its marked path
 * with the text's "/"-separated parts in the variable segments, in order.
 * Each part is already a /proc entry name, as the canonical text writes
 * its segments, so none is encoded again. A type the schema does not mark,
 * or a text of another number of parts or with an empty part, names
 * nothing: undefined. A part is not checked against its segment's grammar:
 * the line reads the path, and a part erx_present:parse/2 would refuse
 * names no entry there (erx_procfs_core:child/2 takes only canonical names).
 */
export function presentationPath(type: string, text: string): readonly string[] | undefined {
  const pattern = PRESENTATIONS.get(type);
  const parts = text.split('/');
  if (pattern === undefined || parts.includes('')) return undefined;
  if (parts.length !== pattern.filter((segment) => 'variable' in segment).length) return undefined;
  let next = 0;
  return pattern.map((segment) => ('literal' in segment ? segment.literal : (parts[next++] as string)));
}
