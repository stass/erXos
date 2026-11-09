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
 * control character, whatever the bytes.
 */

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
