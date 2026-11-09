# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_typescript'
require_relative 'abi_emit_ui_wire'

module Erx
  module ABI
    # Emits web/src/generated/ui_wire.ts, the web client's reader of the
    # records the widget server writes in ui.txt's binary form and writer of
    # the event and pixels records a renderer writes back (docs/design-abi.md,
    # "Widget format"; docs/design-web.md, "The client"). It is the TypeScript
    # twin of the C reader and writer UIWireEmitter emits: the same framing,
    # bounds and refusal reasons, so one parity test covers all three readers.
    # The tables come from the `ui` declaration and the inspection schema's
    # stopgaps; the reader and writer are fixed text.
    module UIWireTSEmitter
      PATH = 'web/src/generated/ui_wire.ts'

      module_function

      def outputs(schema)
        return {} unless schema.ui

        { PATH => typescript(schema.ui, stopgaps: schema.inspection.stopgaps.keys) }.freeze
      end

      def typescript(ui, stopgaps:)
        ts = TypeScript
        wire = UIWireEmitter
        [
          ts.header(source: 'abi/formats/ui.txt', summary: <<~TEXT),
            The reader of the records the widget server writes to a renderer in
            ui.txt's binary form (docs/design-abi.md, "Widget format"): insert,
            remove, set, move, commit, screen, input and repaint; and the writer of
            the records a renderer writes back: event and pixels. A record is a u32
            length, which counts the tag and the fields, then a u8 tag and the
            fields; integers are little-endian. The reader never throws on what it
            is handed: it returns a record, a request for more bytes or a refusal
            with its reason, the reasons of the C reader erx/ui_wire.h declares.
          TEXT
          constants(ui),
          ts.names(constant: 'STATUSES', type: 'Status', members: wire::STATUSES, comment: "A status block's statuses, in code order."),
          ts.names(constant: 'REPORTERS', type: 'Reporter', members: wire::REPORTERS,
                   comment: "A status block's reporters, in code order."),
          ts.names(constant: 'FORMS', type: 'Form', members: wire::FORMS, comment: "A property's forms: which shape its value takes."),
          ts.names(constant: 'DETAILS', type: 'DetailTag', members: wire::DETAILS, comment: "An event's detail tags, in code order."),
          ts.names(constant: 'STOPGAPS', type: 'Stopgap', members: stopgaps,
                   comment: "The inspection schema's stopgap reporters, the names a status may carry."),
          "/* Record tags. */\nconst TAG = Object.freeze({ #{numbered(wire::TAGS)} });\n",
          "/* An input record's forms. */\nconst INPUT = Object.freeze({ #{numbered(wire::INPUT_FORMS)} });\n",
          "/* Kinds by name. */\nexport const KINDS: ReadonlyMap<string, number> = " \
          "#{ts.map(ui.kinds.map { |kind| [ts.string(kind.name), kind.number] }, type: 'string, number')};\n",
          TYPES,
          takes(ui),
          "/* Every property a record may carry, by name: the key is never written. */\n" \
          "export const PROPERTIES: ReadonlyMap<string, PropertyType> = " \
          "#{ts.map(wire.wire_properties(ui).map { |property| [ts.string(property.name), property_type(property, ui)] },
                    type: 'string, PropertyType')};\n",
          CODE
        ].join("\n")
      end

      def numbered(names) = names.each_with_index.map { |name, index| "#{name}: #{index + 1}" }.join(', ')

      # The TypeScript twin of UIWireEmitter.kind_takes: the properties every
      # kind takes and those each kind lists beneath it.
      def takes(ui)
        listed = UIWireEmitter.wire_properties(ui).reject(&:common)
        common = UIWireEmitter.wire_properties(ui).select(&:common).map { |property| TypeScript.string(property.name) }
        own = ui.kinds.map do |kind|
          names = kind.takes.map(&:property).select { |property| listed.include?(property) }
          [TypeScript.string(kind.name), "new Set([#{names.map { |property| TypeScript.string(property.name) }.join(', ')}])"]
        end
        <<~TS
          /* The properties every kind takes. */
          const COMMON: ReadonlySet<string> = new Set([#{common.join(', ')}]);

          /* The properties each kind takes besides the common ones. */
          const KIND_TAKES: ReadonlyMap<string, ReadonlySet<string>> = #{TypeScript.map(own, type: 'string, ReadonlySet<string>')};

          /*
           * Whether a node of KIND takes property PROP: every common property and
           * those listed beneath the kind. The reader decides nothing by kind, so
           * a renderer refuses with this a property its node does not take.
           */
          export function takes(kind: string, prop: string): boolean {
            const own = KIND_TAKES.get(kind);
            return own !== undefined && PROPERTIES.has(prop) && (COMMON.has(prop) || own.has(prop));
          }
        TS
      end

      def constants(ui)
        [
          ['UI_VERSION', ui.version, "ui.txt's version"],
          ['OP_MAX', ui.op_max, 'the longest record but a pixels report, its tag and fields'],
          ['PIXELS_MAX', ui.pixels_max, 'the longest pixels report'],
          ['PIXELS_DATA_MAX', ui.pixels_max - UIWireEmitter::PIXELS_FIELDS, 'the most pixel bytes one pixels report carries'],
          ['EVENT_TEXT_MAX', ui.op_max - UIWireEmitter::EVENT_TEXT_FIELDS, 'the longest text detail of an event'],
          ['PROPERTY_MAX', UIWireEmitter.wire_properties(ui).size, 'the most properties one record carries, each at most once'],
          ['NAME_MAX', UIWireEmitter::NAME_MAX, 'the longest stopgap or presentation name'],
          ['PRESENT_MAX', UIWireEmitter::PRESENT_MAX, "the longest presentation's canonical text"]
        ].map { |name, value, comment| TypeScript.constant(name: name, value: value, comment: comment) }.join
      end

      def property_type(property, ui)
        type = property.type
        fields = { 'name' => TypeScript.string(property.name), 'number' => property.number,
                   'form' => TypeScript.string(type.form), 'status' => property.status ? 'true' : 'false',
                   'minimum' => 0, 'maximum' => 0, 'limit' => 0, 'elementLimit' => 0, 'members' => 'null' }
        case type.form
        when 'integer' then fields.merge!('minimum' => type.minimum, 'maximum' => type.maximum)
        when 'text', 'bytes' then fields['limit'] = type.maximum
        when 'list' then fields.merge!('limit' => type.maximum, 'elementLimit' => type.element.maximum)
        when 'enum' then fields['members'] = members(type.numbers.zip(type.atoms))
        when 'image' then fields['members'] = members(ui.images.map { |image| [image.number, image.name] })
        end
        "{ #{fields.map { |key, value| "#{key}: #{value}" }.join(', ')} }"
      end

      def members(pairs)
        TypeScript.map(pairs.map { |number, name| [number, TypeScript.string(name)] }, type: 'number, string',
                                                                                   indent: '    ')
      end

      TYPES = <<~'TS'
        /*
         * A property's type: its form, an integer's bounds, a text's, bytes' or
         * a list's most bytes or entries, a list text's most bytes, an enum's or
         * image's members by number, and whether a status block precedes it.
         */
        export interface PropertyType {
          readonly name: string;
          readonly number: number;
          readonly form: Form;
          readonly status: boolean;
          readonly minimum: number;
          readonly maximum: number;
          readonly limit: number;
          readonly elementLimit: number;
          readonly members: ReadonlyMap<number, string> | null;
        }
      TS

      CODE = <<~'TS'
        const KIND_NAMES: ReadonlyMap<number, string> = new Map([...KINDS].map(([name, number]) => [number, name]));
        const BY_NUMBER: ReadonlyMap<number, PropertyType> = new Map([...PROPERTIES.values()].map((type) => [type.number, type]));

        /*
         * A presentation's value: its type's name and canonical text, both
         * valid UTF-8.
         */
        export interface Presentation {
          readonly name: Uint8Array;
          readonly text: Uint8Array;
        }

        /*
         * A property's value by its form: a boolean; an integer within its
         * bounds; an enum's or image's member by name; a text's valid UTF-8 or
         * bytes' bytes; a list's texts; a presentation.
         */
        export type Value = boolean | number | string | Uint8Array | readonly Uint8Array[] | Presentation;

        /*
         * One property of an insert or a set. Status, reporter, stopgap and
         * timeoutMs are its status block, and ok, own, "" and 0 for a property
         * that carries none. Value is null for an event, which has none, and for
         * a status that is neither ok nor partial.
         */
        export interface Prop {
          readonly name: string;
          readonly number: number;
          readonly form: Form;
          readonly status: Status;
          readonly reporter: Reporter;
          readonly stopgap: string;
          readonly timeoutMs: number;
          readonly value: Value | null;
        }

        /* An input record's event; a key's rune is null when it has none. */
        export type Input =
          | { readonly form: 'pointer'; readonly x: number; readonly y: number; readonly buttons: number }
          | { readonly form: 'key'; readonly down: boolean; readonly code: number; readonly rune: number | null }
          | { readonly form: 'wheel'; readonly steps: number };

        /* One record of the server's, by its tag. */
        export type UIRecord =
          | {
              readonly tag: 'insert';
              readonly node: number;
              readonly parent: number;
              readonly index: number;
              readonly kind: string;
              readonly props: readonly Prop[];
            }
          | { readonly tag: 'remove'; readonly node: number }
          | { readonly tag: 'set'; readonly node: number; readonly props: readonly Prop[]; readonly removed: readonly string[] }
          | { readonly tag: 'move'; readonly node: number; readonly index: number }
          | { readonly tag: 'commit' }
          | { readonly tag: 'repaint' }
          | { readonly tag: 'screen'; readonly width: number; readonly height: number; readonly chan: number }
          | { readonly tag: 'input'; readonly input: Input };

        /*
         * What read() makes of a buffer's first record: the record and its size,
         * the length word counted; a request for more bytes, the buffer holding
         * no whole record yet; or a refusal and its reason.
         */
        export type ReadResult =
          | { readonly result: 'ok'; readonly record: UIRecord; readonly used: number }
          | { readonly result: 'more' }
          | { readonly result: 'bad'; readonly reason: string };

        /* A refused record, thrown inside the reader and caught by read() alone. */
        class Refusal {
          readonly reason: string;

          constructor(reason: string) {
            this.reason = reason;
          }
        }

        function refuse(reason: string): never {
          throw new Refusal(reason);
        }

        /*
         * What remains of one record's fields. Each read names the reason the
         * record is refused for when the field is not all there.
         */
        class Cursor {
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

        function u16At(bytes: Uint8Array, at: number): number {
          return (bytes[at] as number) | ((bytes[at + 1] as number) << 8);
        }

        function u32At(bytes: Uint8Array, at: number): number {
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

        /* A length of WIDTH 1 or 4 bytes, at most LIMIT, then that many bytes of valid UTF-8. */
        function text(cursor: Cursor, width: 1 | 4, limit: number, reason: string): Uint8Array {
          const length = width === 1 ? cursor.u8(reason) : cursor.u32(reason);
          if (length > limit) refuse(reason);
          const bytes = cursor.take(length, reason);
          if (!isUTF8(bytes)) refuse(reason);
          return bytes;
        }

        /* A status block, and the one a property that carries none has. */
        interface StatusBlock {
          readonly status: Status;
          readonly reporter: Reporter;
          readonly stopgap: string;
          readonly timeoutMs: number;
        }

        const OWN_OK: StatusBlock = Object.freeze({ status: 'ok', reporter: 'own', stopgap: '', timeoutMs: 0 });

        function stopgapNamed(bytes: Uint8Array): string | undefined {
          return STOPGAPS.find((name) => name.length === bytes.length && bytes.every((byte, at) => byte === name.charCodeAt(at)));
        }

        /*
         * The status block: a status and a reporter within their codes, a
         * stopgap's name that is a declared stopgap exactly when the reporter is
         * a stopgap, and a timeout that is set exactly when the status is
         * timeout. The application's own value is always ok.
         */
        function statusBlock(cursor: Cursor): StatusBlock {
          const statusCode = cursor.u8('bad status');
          const reporterCode = cursor.u8('bad status');
          const stopgapBytes = text(cursor, 1, NAME_MAX, 'bad status');
          const timeoutMs = cursor.u32('bad status');
          const status = STATUSES[statusCode];
          const reporter = REPORTERS[reporterCode];
          if (status === undefined || reporter === undefined) refuse('bad status');
          if (reporter === 'own' && status !== 'ok') refuse('bad status');
          if ((status === 'timeout') !== (timeoutMs !== 0)) refuse('bad status');
          const stopgap = stopgapNamed(stopgapBytes);
          if (reporter === 'stopgap' ? stopgap === undefined : stopgapBytes.length !== 0) refuse('bad status');
          return { status, reporter, stopgap: stopgap ?? '', timeoutMs };
        }

        /* A value of TYPE, bounded by the type and by what remains. */
        function value(cursor: Cursor, type: PropertyType): Value | null {
          const reason = 'bad value';
          switch (type.form) {
            case 'boolean': {
              const byte = cursor.u8(reason);
              if (byte > 1) refuse(reason);
              return byte === 1;
            }
            case 'integer': {
              /* The u32's two's-complement value: | 0 reads it as a signed 32-bit integer. */
              const integer = cursor.u32(reason) | 0;
              if (integer < type.minimum || integer > type.maximum) refuse(reason);
              return integer;
            }
            case 'enum':
            case 'image':
              return type.members?.get(cursor.u8(reason)) ?? refuse(reason);
            case 'text':
              return text(cursor, 4, type.limit, reason);
            case 'bytes': {
              const length = cursor.u32(reason);
              if (length > type.limit) refuse(reason);
              return cursor.take(length, reason);
            }
            case 'list': {
              const count = cursor.u16(reason);
              if (count > type.limit) refuse(reason);
              return Array.from({ length: count }, () => text(cursor, 4, type.elementLimit, reason));
            }
            case 'event':
              return null;
            case 'presentation':
              return { name: text(cursor, 1, NAME_MAX, reason), text: text(cursor, 4, PRESENT_MAX, reason) };
          }
        }

        /* A node's number, never 0. */
        function node(cursor: Cursor): number {
          const number = cursor.u32('bad node');
          return number !== 0 ? number : refuse('bad node');
        }

        /* A u8 count and each property: a known number, once, and its value. */
        function props(cursor: Cursor): Prop[] {
          const count = cursor.u8('short record');
          if (count > PROPERTY_MAX) refuse('too many properties');
          const seen = new Set<number>();
          return Array.from({ length: count }, () => {
            const number = cursor.u8('short record');
            const type = BY_NUMBER.get(number) ?? refuse('unknown property');
            if (seen.has(number)) refuse('property twice');
            seen.add(number);
            const block = type.status ? statusBlock(cursor) : OWN_OK;
            const carried = block.status === 'ok' || block.status === 'partial';
            return { name: type.name, number, form: type.form, ...block, value: carried ? value(cursor, type) : null };
          });
        }

        /* A set's removals: a u8 count of known property numbers, each once. */
        function removed(cursor: Cursor): string[] {
          const count = cursor.u8('short record');
          if (count > PROPERTY_MAX) refuse('too many properties');
          const seen = new Set<number>();
          return Array.from({ length: count }, () => {
            const number = cursor.u8('short record');
            const type = BY_NUMBER.get(number) ?? refuse('unknown property');
            if (seen.has(number)) refuse('property twice');
            seen.add(number);
            return type.name;
          });
        }

        function input(cursor: Cursor): Input {
          const reason = 'short record';
          switch (cursor.u8(reason)) {
            case INPUT.pointer:
              return { form: 'pointer', x: cursor.u16(reason), y: cursor.u16(reason), buttons: cursor.u8(reason) };
            case INPUT.key: {
              const down = cursor.u8(reason);
              const code = cursor.u16(reason);
              const rune = cursor.u32(reason);
              if (down > 1) refuse('bad key direction');
              if (rune !== 0xffffffff && (rune > 0x10ffff || (rune >= 0xd800 && rune <= 0xdfff))) refuse('bad rune');
              return { form: 'key', down: down === 1, code, rune: rune === 0xffffffff ? null : rune };
            }
            case INPUT.wheel:
              /* A signed u8: shifted to the top of 32 bits and back, extending its sign. */
              return { form: 'wheel', steps: (cursor.u8(reason) << 24) >> 24 };
            default:
              return refuse('unknown input form');
          }
        }

        /* The fields of one record, by its tag. */
        function fields(cursor: Cursor, tag: number): UIRecord {
          switch (tag) {
            case TAG.insert: {
              const number = node(cursor);
              const parent = cursor.u32('bad node');
              const index = cursor.u16('bad node');
              const kind = KIND_NAMES.get(cursor.u8('bad node')) ?? refuse('unknown kind');
              return { tag: 'insert', node: number, parent, index, kind, props: props(cursor) };
            }
            case TAG.remove:
              return { tag: 'remove', node: node(cursor) };
            case TAG.set: {
              const number = node(cursor);
              const changed = props(cursor);
              return { tag: 'set', node: number, props: changed, removed: removed(cursor) };
            }
            case TAG.move:
              return { tag: 'move', node: node(cursor), index: cursor.u16('bad node') };
            case TAG.commit:
              return { tag: 'commit' };
            case TAG.repaint:
              return { tag: 'repaint' };
            case TAG.screen: {
              const reason = 'short record';
              return { tag: 'screen', width: cursor.u16(reason), height: cursor.u16(reason), chan: cursor.u32(reason) };
            }
            case TAG.input:
              return { tag: 'input', input: input(cursor) };
            default:
              /* Event and pixels go the other way; a renderer refuses them. */
              return refuse('unknown tag');
          }
        }

        /*
         * Read the first record of BUFFER. A record whose length exceeds OP_MAX
         * is refused before its bytes arrive, so a caller never buffers more
         * than OP_MAX + 4 bytes. The record's bytes are copied out of BUFFER.
         */
        export function read(buffer: Uint8Array): ReadResult {
          if (buffer.length < 4) return { result: 'more' };
          const size = u32At(buffer, 0);
          if (size === 0 || size > OP_MAX) return { result: 'bad', reason: 'bad length' };
          if (size > buffer.length - 4) return { result: 'more' };
          const cursor = new Cursor(buffer, 4, 4 + size);
          try {
            const record = fields(cursor, cursor.u8('short record'));
            if (cursor.left !== 0) refuse('bytes left over');
            return { result: 'ok', record, used: 4 + size };
          } catch (error) {
            if (error instanceof Refusal) return { result: 'bad', reason: error.reason };
            throw error;
          }
        }

        /* An event's detail; a text is valid UTF-8 of at most EVENT_TEXT_MAX bytes. */
        export type Detail =
          | { readonly tag: 'none' }
          | { readonly tag: 'boolean'; readonly value: boolean }
          | { readonly tag: 'integer'; readonly value: number }
          | { readonly tag: 'text'; readonly value: Uint8Array };

        /* Where an event's value and a pixels report's pixels start, the length word counted. */
        const EVENT_VALUE_AT = 4 + 1 + 4 + 1 + 1;
        const PIXELS_AT = 4 + 1 + 4 * 2;

        function isUnsigned(value: number, bits: 16 | 32): boolean {
          return Number.isInteger(value) && value >= 0 && value < 2 ** bits;
        }

        /* A record of BODY bytes after its tag: the length word and the tag written, the rest zero. */
        function frame(tag: number, body: number): [Uint8Array, DataView] {
          const bytes = new Uint8Array(4 + 1 + body);
          const view = new DataView(bytes.buffer);
          view.setUint32(0, 1 + body, true);
          bytes[4] = tag;
          return [bytes, view];
        }

        /*
         * The event record of NODE's event property named EVENT with DETAIL, its
         * length word included; null when refused: a node outside 1..2^32-1, a
         * name that is not an event property's, an integer outside a signed u32,
         * or text that is not valid UTF-8 or longer than EVENT_TEXT_MAX.
         */
        export function writeEvent(node: number, event: string, detail: Detail): Uint8Array | null {
          const type = PROPERTIES.get(event);
          if (!isUnsigned(node, 32) || node === 0 || type?.form !== 'event') return null;
          let size: number;
          switch (detail.tag) {
            case 'none':
              size = 0;
              break;
            case 'boolean':
              if (typeof detail.value !== 'boolean') return null;
              size = 1;
              break;
            case 'integer':
              if (!Number.isInteger(detail.value) || detail.value < -(2 ** 31) || detail.value >= 2 ** 31) return null;
              size = 4;
              break;
            case 'text':
              if (detail.value.length > EVENT_TEXT_MAX || !isUTF8(detail.value)) return null;
              size = 4 + detail.value.length;
              break;
            default:
              return null;
          }
          /* After the length word and tag: the node, the event's number, the detail's tag, its value. */
          const [bytes, view] = frame(TAG.event, 4 + 1 + 1 + size);
          const value = EVENT_VALUE_AT;
          view.setUint32(5, node, true);
          bytes[9] = type.number;
          bytes[10] = DETAILS.indexOf(detail.tag);
          if (detail.tag === 'boolean') bytes[value] = detail.value ? 1 : 0;
          if (detail.tag === 'integer') view.setInt32(value, detail.value, true);
          if (detail.tag === 'text') {
            view.setUint32(value, detail.value.length, true);
            bytes.set(detail.value, value + 4);
          }
          return bytes;
        }

        /*
         * The pixels record of the rectangle at X and Y of WIDTH by HEIGHT and
         * its PIXELS, its length word included; null when a coordinate is not a
         * u16 or the pixels exceed PIXELS_DATA_MAX bytes. Whether their length is
         * the rectangle's size at the target's depth is for the reader to check.
         */
        export function writePixels(x: number, y: number, width: number, height: number, pixels: Uint8Array): Uint8Array | null {
          if (![x, y, width, height].every((value) => isUnsigned(value, 16)) || pixels.length > PIXELS_DATA_MAX) return null;
          /* After the length word and tag: x, y, width and height, then the pixels at PIXELS_AT. */
          const [bytes, view] = frame(TAG.pixels, 4 * 2 + pixels.length);
          view.setUint16(5, x, true);
          view.setUint16(7, y, true);
          view.setUint16(9, width, true);
          view.setUint16(11, height, true);
          bytes.set(pixels, PIXELS_AT);
          return bytes;
        }
      TS
    end
  end
end
