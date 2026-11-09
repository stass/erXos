/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The runtime every generated reader and writer of the web client shares
 * (docs/design-web.md, "The client"): the cursor over an input's bytes and
 * the refusal it throws, the writer of an output, little-endian loads and
 * the UTF-8 check. The generated modules of src/generated import it; it
 * holds no table of any ABI source, so it is a source of its own and not
 * generated. The check is not text.ts's decoder, which yields the units the
 * escape needs: a reader only asks whether a text is valid, without a unit
 * list per text.
 */

/* A refused input, thrown inside a reader and caught by that reader's entry point alone. */
export class Refusal {
  readonly reason: string;

  constructor(reason: string) {
    this.reason = reason;
  }
}

export function refuse(reason: string): never {
  throw new Refusal(reason);
}

/*
 * What remains of one record's or message's fields. Each read names the reason the
 * record is refused for when the field is not all there.
 */
export class Cursor {
  readonly bytes: Uint8Array;
  readonly end: number;
  at: number;

  constructor(bytes: Uint8Array, at: number, end: number) {
    this.bytes = bytes;
    this.at = at;
    this.end = end;
  }

  get left(): number {
    return this.end - this.at;
  }

  /*
   * COUNT bytes, copied, so a record outlives the buffer it came in;
   * Uint8Array's own slice, since a Node Buffer's returns a view.
   */
  take(count: number, reason: string): Uint8Array {
    if (count > this.left) refuse(reason);
    this.at += count;
    return Uint8Array.prototype.slice.call(this.bytes, this.at - count, this.at);
  }

  u8(reason: string): number {
    if (this.left < 1) refuse(reason);
    return this.bytes[this.at++] as number;
  }

  u16(reason: string): number {
    if (this.left < 2) refuse(reason);
    this.at += 2;
    return u16At(this.bytes, this.at - 2);
  }

  u32(reason: string): number {
    if (this.left < 4) refuse(reason);
    this.at += 4;
    return u32At(this.bytes, this.at - 4);
  }
}

/* The bytes of one output of at most MAX bytes, refused with REASON once it would pass them. */
export class Writer {
  readonly bytes: Uint8Array;
  readonly reason: string;
  at = 0;

  constructor(max: number, reason: string) {
    this.bytes = new Uint8Array(max);
    this.reason = reason;
  }

  room(count: number): void {
    if (count > this.bytes.length - this.at) refuse(this.reason);
  }

  /* VALUE's low BYTES bytes, little-endian. */
  integer(bytes: 1 | 2 | 4, value: number): void {
    this.room(bytes);
    for (let index = 0; index < bytes; index++) this.bytes[this.at++] = (value >>> (8 * index)) & 0xff;
  }

  put(bytes: Uint8Array): void {
    this.room(bytes.length);
    this.bytes.set(bytes, this.at);
    this.at += bytes.length;
  }

  /* BYTES after their length as a u32. */
  sized(bytes: Uint8Array): void {
    this.integer(4, bytes.length);
    this.put(bytes);
  }

  /* What has been written, copied. */
  written(): Uint8Array {
    return this.bytes.slice(0, this.at);
  }
}

export function u16At(bytes: Uint8Array, at: number): number {
  return (bytes[at] as number) | ((bytes[at + 1] as number) << 8);
}

export function u32At(bytes: Uint8Array, at: number): number {
  return (u16At(bytes, at) | (u16At(bytes, at + 2) << 16)) >>> 0;
}

/* Decode each scalar once, refusing overlong forms and surrogates. */
export function isUTF8(bytes: Uint8Array): boolean {
  let at = 0;
  while (at < bytes.length) {
    const first = bytes[at++] as number;
    let continuation: number;
    let minimum: number;
    let point: number;
    if (first < 0x80) {
      continue;
    } else if (first >= 0xc2 && first <= 0xdf) {
      point = first & 0x1f;
      continuation = 1;
      minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      point = first & 0x0f;
      continuation = 2;
      minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      point = first & 0x07;
      continuation = 3;
      minimum = 0x10000;
    } else {
      return false;
    }
    if (continuation > bytes.length - at) return false;
    for (let index = 0; index < continuation; index++) {
      const next = bytes[at++] as number;
      if ((next & 0xc0) !== 0x80) return false;
      point = (point << 6) | (next & 0x3f);
    }
    if (point < minimum || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) return false;
  }
  return true;
}

