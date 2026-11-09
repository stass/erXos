# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_typescript'
require_relative 'abi_emit_ui_wire'
require_relative 'abi_emit_ui_fields'

module Erx
  module ABI
    # Emits web/src/generated/ui_wire.ts, the web client's reader and writer
    # of both directions of ui.txt's binary form (docs/design-abi.md, "Widget
    # format"; docs/design-web.md, "The client"): of the records the widget
    # server writes, whose texts it reads as MachineText (rule W2), and of the
    # event and pixels records a renderer writes back. Its reader of the
    # server's records is the TypeScript twin of the C reader and of
    # erx_ui_wire:read_server/1, with the same framing, bounds and refusal
    # reasons, so one parity test covers all three readers; its reader of
    # reports is erx_ui_wire:read/1's. The tables come from the `ui`
    # declaration and the inspection schema's stopgaps; the code is fixed text.
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
        fields = UIFields
        [
          ts.header(source: 'abi/formats/ui.txt', summary: <<~TEXT),
            The reader and writer of ui.txt's binary form in both directions
            (docs/design-abi.md, "Widget format"): read() and writeRecord() of the
            records the widget server writes to a renderer, insert, remove, set,
            move, commit, screen, input and repaint; and readReport(), writeEvent()
            and writePixels() of the records a renderer writes back, event and
            pixels. A record is a u32 length, which counts the tag and the fields,
            then a u8 tag and the fields; integers are little-endian. read() hands
            every text out as a MachineText. The readers never throw on what they
            are handed: they return a record, a request for more bytes or a
            refusal with its reason, read()'s those of the C reader erx/ui_wire.h
            declares and readReport()'s those of erx_ui_wire:read/1. The writers
            return null for what a reader would refuse.
          TEXT
          "import { MachineText } from '../text.ts';\nimport { Cursor, Refusal, Writer, isUTF8, refuse, u32At } from '../wire.ts';\n\n" \
            "/* The UTF-8 check of the shared runtime, offered to the callers of this module too. */\n" \
            "export { isUTF8 };\n",
          constants(ui),
          ts.names(constant: 'STATUSES', type: 'Status', members: wire::STATUSES, comment: "A status block's statuses, in code order."),
          ts.names(constant: 'REPORTERS', type: 'Reporter', members: wire::REPORTERS,
                   comment: "A status block's reporters, in code order."),
          ts.names(constant: 'FORMS', type: 'Form', members: wire::FORMS, comment: "A property's forms: which shape its value takes."),
          ts.names(constant: 'DETAILS', type: 'DetailTag', members: wire::DETAILS, comment: "An event's detail tags, in code order."),
          ts.names(constant: 'STOPGAPS', type: 'Stopgap', members: stopgaps,
                   comment: "The inspection schema's stopgap reporters, the names a status may carry."),
          "/* Record tags. */\nconst TAG = Object.freeze({ #{pairs(wire.tags(ui))} });\n",
          "/* An input record's forms. */\nconst INPUT = Object.freeze({ #{pairs(ui.inputs.map { |form| [form.name, form.number] })} });\n",
          fields.ts_refusals,
          "/* Kinds by name. */\nexport const KINDS: ReadonlyMap<string, number> = " \
          "#{ts.map(ui.kinds.map { |kind| [ts.string(kind.name), kind.number] }, type: 'string, number')};\n",
          TYPES,
          takes(ui),
          "/* Every property a record may carry, by name: the key is never written. */\n" \
          "export const PROPERTIES: ReadonlyMap<string, PropertyType> = " \
          "#{ts.map(wire.wire_properties(ui).map { |property| [ts.string(property.name), property_type(property, ui)] },
                    type: 'string, PropertyType')};\n",
          CODE,
          record_types(ui),
          CODE_READER,
          record_reader(ui),
          CODE_WRITER,
          record_writer(ui),
          CODE_VALUE_WRITER,
          input_writer(ui),
          CODE_REPORTS
        ].join("\n")
      end

      def pairs(named) = named.map { |name, number| "#{name}: #{number}" }.join(', ')

      # The server's records and the input forms as ui.txt declares them.
      def record_types(ui)
        types = UIFields.ts_types(ui)
        "/* An input record's event; a key's rune is null when it has none. */\n" \
          "export type Input =\n#{types.fetch(:input).map { |type| "  | #{type}" }.join("\n")};\n\n" \
          "/* One record of the server's, by its tag. */\n" \
          "export type UIRecord<T = MachineText> =\n#{types.fetch(:records).map { |type| "  | #{type}" }.join("\n")};\n"
      end

      def record_reader(ui)
        <<~TS
          /* An input record's event: its form, and the form's fields. */
          function readInput(cursor: Cursor, cut: string): Input {
            switch (cursor.u8(cut)) {
          #{UIFields.ts_input_cases(ui)}    default:
                return refuse(REFUSAL.unknownInputForm);
            }
          }

          /* The fields of one record, by its tag, as ui.txt declares them. */
          function fields(cursor: Cursor, tag: number): UIRecord {
            switch (tag) {
          #{UIFields.ts_read_cases(ui)}    default:
                /* The reports go the other way; a renderer refuses them. */
                return refuse(REFUSAL.unknownTag);
            }
          }
        TS
      end

      def record_writer(ui)
        <<~TS
          function writeFields(writer: Writer, record: UIRecord<Uint8Array>): void {
            writer.integer(1, TAG[record.tag]);
            switch (record.tag) {
          #{UIFields.ts_write_cases(ui)}
            }
          }
        TS
      end

      def input_writer(ui)
        <<~TS
          function writeInput(writer: Writer, input: Input): void {
            switch (input.form) {
          #{UIFields.ts_input_write_cases(ui)}
            }
          }
        TS
      end

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
         * A record's texts are of the text type T: MachineText in what read()
         * returns, so a text the machine sends reaches the DOM only through its line
         * escape (docs/design-web.md, rule W2), and Uint8Array in what writeRecord()
         * takes, the bytes themselves.
         */

        /* A presentation's value: its type's name and canonical text, both valid UTF-8. */
        export interface Presentation<T> {
          readonly name: T;
          readonly text: T;
        }

        /*
         * A property's value by its form: a boolean; an integer within its bounds;
         * an enum's or image's member by name; a text of valid UTF-8; bytes; a
         * list's texts; a presentation. It is null for an event, which has none,
         * and for a status that is neither ok nor partial.
         */
        export type FormValue<T> =
          | { readonly form: 'boolean'; readonly value: boolean | null }
          | { readonly form: 'integer'; readonly value: number | null }
          | { readonly form: 'enum' | 'image'; readonly value: string | null }
          | { readonly form: 'text'; readonly value: T | null }
          | { readonly form: 'bytes'; readonly value: Uint8Array | null }
          | { readonly form: 'list'; readonly value: readonly T[] | null }
          | { readonly form: 'event'; readonly value: null }
          | { readonly form: 'presentation'; readonly value: Presentation<T> | null };

        /*
         * One property of an insert or a set, its value discriminated by its form.
         * Status, reporter, stopgap and timeoutMs are its status block, and ok, own,
         * "" and 0 for a property that carries none.
         */
        export type Prop<T = MachineText> = {
          readonly name: string;
          readonly number: number;
          readonly status: Status;
          readonly reporter: Reporter;
          readonly stopgap: string;
          readonly timeoutMs: number;
        } & FormValue<T>;

      TS

      CODE_READER = <<~'TS'
        /*
         * What read() makes of a buffer's first record: the record and its size,
         * the length word counted; a request for more bytes, the buffer holding
         * no whole record yet; or a refusal and its reason.
         */
        export type ReadResult =
          | { readonly result: 'ok'; readonly record: UIRecord; readonly used: number }
          | { readonly result: 'more' }
          | { readonly result: 'bad'; readonly reason: string };

        /* A length of WIDTH 1 or 4 bytes, at most LIMIT, then that many bytes of valid UTF-8. */
        function text(cursor: Cursor, width: 1 | 4, limit: number, reason: string): Uint8Array {
          const length = width === 1 ? cursor.u8(reason) : cursor.u32(reason);
          if (length > limit) refuse(reason);
          const bytes = cursor.take(length, reason);
          if (!isUTF8(bytes)) refuse(reason);
          return bytes;
        }

        /* A text the machine sends, as the client holds it. */
        const machineText = (cursor: Cursor, width: 1 | 4, limit: number): MachineText =>
          new MachineText(text(cursor, width, limit, REFUSAL.badValue));

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
          const statusCode = cursor.u8(REFUSAL.badStatus);
          const reporterCode = cursor.u8(REFUSAL.badStatus);
          const stopgapBytes = text(cursor, 1, NAME_MAX, REFUSAL.badStatus);
          const timeoutMs = cursor.u32(REFUSAL.badStatus);
          const status = STATUSES[statusCode];
          const reporter = REPORTERS[reporterCode];
          if (status === undefined || reporter === undefined) refuse(REFUSAL.badStatus);
          if (reporter === 'own' && status !== 'ok') refuse(REFUSAL.badStatus);
          if ((status === 'timeout') !== (timeoutMs !== 0)) refuse(REFUSAL.badStatus);
          const stopgap = stopgapNamed(stopgapBytes);
          if (reporter === 'stopgap' ? stopgap === undefined : stopgapBytes.length !== 0) refuse(REFUSAL.badStatus);
          return { status, reporter, stopgap: stopgap ?? '', timeoutMs };
        }

        /*
         * The value of TYPE when CARRIED, bounded by the type and by what remains,
         * with the form that says its shape; a null value when not carried.
         */
        function value(cursor: Cursor, type: PropertyType, carried: boolean): FormValue<MachineText> {
          switch (type.form) {
            case 'boolean':
              return { form: type.form, value: carried ? readBoolean(cursor, REFUSAL.badValue) : null };
            case 'integer':
              return { form: type.form, value: carried ? readInteger(cursor, type) : null };
            case 'enum':
            case 'image':
              return { form: type.form, value: carried ? (type.members?.get(cursor.u8(REFUSAL.badValue)) ?? refuse(REFUSAL.badValue)) : null };
            case 'text':
              return { form: type.form, value: carried ? machineText(cursor, 4, type.limit) : null };
            case 'bytes':
              return { form: type.form, value: carried ? readBytes(cursor, type) : null };
            case 'list':
              return { form: type.form, value: carried ? readList(cursor, type) : null };
            case 'event':
              return { form: type.form, value: null };
            case 'presentation':
              return {
                form: type.form,
                value: carried ? { name: machineText(cursor, 1, NAME_MAX), text: machineText(cursor, 4, PRESENT_MAX) } : null,
              };
          }
        }

        function readBoolean(cursor: Cursor, reason: string): boolean {
          const byte = cursor.u8(reason);
          if (byte > 1) refuse(reason);
          return byte === 1;
        }

        function readInteger(cursor: Cursor, type: PropertyType): number {
          /* The u32's two's-complement value: | 0 reads it as a signed 32-bit integer. */
          const integer = cursor.u32(REFUSAL.badValue) | 0;
          if (integer < type.minimum || integer > type.maximum) refuse(REFUSAL.badValue);
          return integer;
        }

        function readBytes(cursor: Cursor, type: PropertyType): Uint8Array {
          const length = cursor.u32(REFUSAL.badValue);
          if (length > type.limit) refuse(REFUSAL.badValue);
          return cursor.take(length, REFUSAL.badValue);
        }

        function readList(cursor: Cursor, type: PropertyType): MachineText[] {
          const count = cursor.u16(REFUSAL.badValue);
          if (count > type.limit) refuse(REFUSAL.badValue);
          return Array.from({ length: count }, () => machineText(cursor, 4, type.elementLimit));
        }

        /* A node's number, never 0. */
        function nodeId(number: number): number {
          return number !== 0 ? number : refuse(REFUSAL.badNode);
        }

        function kindName(number: number): string {
          return KIND_NAMES.get(number) ?? refuse(REFUSAL.unknownKind);
        }

        /* A key's down 1 or up 0. */
        function direction(byte: number): boolean {
          return byte <= 1 ? byte === 1 : refuse(REFUSAL.badKeyDirection);
        }

        /* A Unicode scalar value, or null for 0xffffffff. */
        function rune(word: number): number | null {
          if (word === 0xffffffff) return null;
          return word <= 0x10ffff && (word < 0xd800 || word > 0xdfff) ? word : refuse(REFUSAL.badRune);
        }

        /* A u8 count and each property: a known number, once, and its value. */
        function readProps(cursor: Cursor): Prop[] {
          const count = cursor.u8(REFUSAL.shortRecord);
          if (count > PROPERTY_MAX) refuse(REFUSAL.tooManyProperties);
          const seen = new Set<number>();
          return Array.from({ length: count }, () => {
            const number = cursor.u8(REFUSAL.shortRecord);
            const type = BY_NUMBER.get(number) ?? refuse(REFUSAL.unknownProperty);
            if (seen.has(number)) refuse(REFUSAL.propertyTwice);
            seen.add(number);
            const block = type.status ? statusBlock(cursor) : OWN_OK;
            const carried = block.status === 'ok' || block.status === 'partial';
            return { name: type.name, number, ...block, ...value(cursor, type, carried) };
          });
        }

        /* A set's removals: a u8 count of known property numbers, each once. */
        function readRemoved(cursor: Cursor): string[] {
          const count = cursor.u8(REFUSAL.shortRecord);
          if (count > PROPERTY_MAX) refuse(REFUSAL.tooManyProperties);
          const seen = new Set<number>();
          return Array.from({ length: count }, () => {
            const number = cursor.u8(REFUSAL.shortRecord);
            const type = BY_NUMBER.get(number) ?? refuse(REFUSAL.unknownProperty);
            if (seen.has(number)) refuse(REFUSAL.propertyTwice);
            seen.add(number);
            return type.name;
          });
        }

      TS

      CODE_WRITER = <<~'TS'
        /*
         * Read the first record of BUFFER. A record whose length exceeds OP_MAX
         * is refused before its bytes arrive, so a caller never buffers more
         * than OP_MAX + 4 bytes. The record's bytes are copied out of BUFFER.
         */
        export function read(buffer: Uint8Array): ReadResult {
          if (buffer.length < 4) return { result: 'more' };
          const size = u32At(buffer, 0);
          if (size === 0 || size > OP_MAX) return { result: 'bad', reason: REFUSAL.badLength };
          if (size > buffer.length - 4) return { result: 'more' };
          const cursor = new Cursor(buffer, 4, 4 + size);
          try {
            const record = fields(cursor, cursor.u8(REFUSAL.shortRecord));
            if (cursor.left !== 0) refuse(REFUSAL.bytesLeftOver);
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

        function isUnsigned(value: number, bits: number): boolean {
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

        /*
         * The bytes of a record of the server's, its length word included, as the
         * widget server writes it; null when the record breaks a rule a reader
         * checks or is longer than OP_MAX. Its properties and removals are written
         * in the order given, and its texts are the bytes themselves.
         */
        export function writeRecord(record: UIRecord<Uint8Array>): Uint8Array | null {
          const writer = new Writer(4 + OP_MAX, 'too long');
          try {
            writer.integer(4, 0);
            writeFields(writer, record);
            const bytes = writer.written();
            new DataView(bytes.buffer).setUint32(0, bytes.length - 4, true);
            return bytes;
          } catch (error) {
            if (error instanceof Refusal) return null;
            throw error;
          }
        }

      TS

      CODE_VALUE_WRITER = <<~'TS'
        function writeUnsigned(writer: Writer, bytes: 1 | 2 | 4, value: number): void {
          if (!isUnsigned(value, 8 * bytes)) refuse('bad value');
          writer.integer(bytes, value);
        }

        function writeSigned8(writer: Writer, value: number): void {
          if (!Number.isInteger(value) || value < -128 || value > 127) refuse(REFUSAL.badValue);
          writer.integer(1, value);
        }

        function writeRune(writer: Writer, rune: number | null): void {
          if (rune !== null && (!isUnsigned(rune, 32) || rune > 0x10ffff || (rune >= 0xd800 && rune <= 0xdfff))) refuse(REFUSAL.badRune);
          writer.integer(4, rune ?? 0xffffffff);
        }

        function writeNode(writer: Writer, node: number): void {
          if (node === 0) refuse('bad node');
          writeUnsigned(writer, 4, node);
        }

        /* A u8 count and each property: a known name of its number and form, once, and its value. */
        function writeProps(writer: Writer, props: readonly Prop<Uint8Array>[]): void {
          if (props.length > PROPERTY_MAX) refuse('too many properties');
          writer.integer(1, props.length);
          const seen = new Set<number>();
          for (const prop of props) {
            const type = PROPERTIES.get(prop.name) ?? refuse('unknown property');
            if (type.number !== prop.number || type.form !== prop.form) refuse('unknown property');
            if (seen.has(type.number)) refuse('property twice');
            seen.add(type.number);
            writer.integer(1, type.number);
            if (type.status) writeStatus(writer, prop);
            else if (prop.status !== 'ok' || prop.reporter !== 'own' || prop.stopgap !== '' || prop.timeoutMs !== 0) refuse('bad status');
            const carried = prop.status === 'ok' || prop.status === 'partial';
            if (prop.form !== 'event' && carried !== (prop.value !== null)) refuse('bad value');
            if (carried) writeValue(writer, type, prop);
          }
        }

        /* The status block, under the rules statusBlock() reads it by. */
        function writeStatus(writer: Writer, prop: Prop<Uint8Array>): void {
          const status = STATUSES.indexOf(prop.status);
          const reporter = REPORTERS.indexOf(prop.reporter);
          if (status < 0 || reporter < 0 || (prop.reporter === 'own' && prop.status !== 'ok')) refuse('bad status');
          if (!isUnsigned(prop.timeoutMs, 32) || (prop.status === 'timeout') !== (prop.timeoutMs !== 0)) refuse('bad status');
          const named = STOPGAPS.some((name) => name === prop.stopgap);
          if (prop.reporter === 'stopgap' ? !named : prop.stopgap !== '') refuse('bad status');
          const stopgap = new TextEncoder().encode(prop.stopgap);
          writer.integer(1, status);
          writer.integer(1, reporter);
          writer.integer(1, stopgap.length);
          writer.put(stopgap);
          writer.integer(4, prop.timeoutMs);
        }

        function writeValue(writer: Writer, type: PropertyType, prop: Prop<Uint8Array>): void {
          const reason = 'bad value';
          switch (prop.form) {
            case 'boolean':
              if (typeof prop.value !== 'boolean') refuse(reason);
              writer.integer(1, prop.value ? 1 : 0);
              return;
            case 'integer':
              if (prop.value === null || !Number.isInteger(prop.value) || prop.value < type.minimum || prop.value > type.maximum) refuse(reason);
              writer.integer(4, prop.value);
              return;
            case 'enum':
            case 'image': {
              const member = [...(type.members ?? [])].find(([, name]) => name === prop.value);
              writer.integer(1, member?.[0] ?? refuse(reason));
              return;
            }
            case 'text':
              writeText(writer, 4, type.limit, prop.value);
              return;
            case 'bytes':
              if (prop.value === null || prop.value.length > type.limit) refuse(reason);
              writer.sized(prop.value);
              return;
            case 'list':
              if (prop.value === null || prop.value.length > type.limit) refuse(reason);
              writer.integer(2, prop.value.length);
              for (const entry of prop.value) writeText(writer, 4, type.elementLimit, entry);
              return;
            case 'event':
              return;
            case 'presentation':
              if (prop.value === null) refuse(reason);
              writeText(writer, 1, NAME_MAX, prop.value.name);
              writeText(writer, 4, PRESENT_MAX, prop.value.text);
              return;
          }
        }

        /* A length of WIDTH bytes and the bytes: valid UTF-8 of at most LIMIT bytes. */
        function writeText(writer: Writer, width: 1 | 4, limit: number, bytes: Uint8Array | null): void {
          if (bytes === null || bytes.length > limit || !isUTF8(bytes)) refuse('bad value');
          writer.integer(width, bytes.length);
          writer.put(bytes);
        }

        /* A set's removals: a u8 count of known property names, each once. */
        function writeRemoved(writer: Writer, removed: readonly string[]): void {
          if (removed.length > PROPERTY_MAX) refuse('too many properties');
          writer.integer(1, removed.length);
          const seen = new Set<number>();
          for (const name of removed) {
            const number = PROPERTIES.get(name)?.number ?? refuse('unknown property');
            if (seen.has(number)) refuse('property twice');
            seen.add(number);
            writer.integer(1, number);
          }
        }

      TS

      CODE_REPORTS = <<~'TS'
        /* A record a renderer writes back: an event, or a pixels report. */
        export type Report =
          | { readonly tag: 'event'; readonly node: number; readonly event: string; readonly detail: Detail }
          | {
              readonly tag: 'pixels';
              readonly x: number;
              readonly y: number;
              readonly width: number;
              readonly height: number;
              readonly pixels: Uint8Array;
            };

        /* What readReport() makes of a buffer's first record, as ReadResult says of read(). */
        export type ReportResult =
          | { readonly result: 'ok'; readonly report: Report; readonly used: number }
          | { readonly result: 'more' }
          | { readonly result: 'bad'; readonly reason: string };

        /*
         * Read the first record of BUFFER that a renderer writes back, as
         * erx_ui_wire:read/1 does, with its reasons in words. A pixels report is at
         * most PIXELS_MAX long and any other record OP_MAX, refused as soon as its
         * tag is in, so a caller never buffers more than PIXELS_MAX + 4 bytes. The
         * pixels are framed by the length alone; their count and rectangle are for
         * the caller, which knows the target, to check.
         */
        export function readReport(buffer: Uint8Array): ReportResult {
          if (buffer.length < 4) return { result: 'more' };
          const size = u32At(buffer, 0);
          if (size === 0 || size > PIXELS_MAX) return { result: 'bad', reason: 'bad length' };
          if (buffer.length < 5) return { result: 'more' };
          const tag = buffer[4] as number;
          if (tag !== TAG.pixels && size > OP_MAX) return { result: 'bad', reason: 'bad length' };
          if (size > buffer.length - 4) return { result: 'more' };
          try {
            return { result: 'ok', report: report(new Cursor(buffer, 5, 4 + size), tag), used: 4 + size };
          } catch (error) {
            if (error instanceof Refusal) return { result: 'bad', reason: error.reason };
            throw error;
          }
        }

        function report(cursor: Cursor, tag: number): Report {
          switch (tag) {
            case TAG.event: {
              const node = cursor.u32('bad body');
              const type = BY_NUMBER.get(cursor.u8('bad body'));
              if (node === 0) refuse('bad node');
              if (type?.form !== 'event') refuse('bad event');
              return { tag: 'event', node, event: type.name, detail: detail(cursor) };
            }
            case TAG.pixels: {
              const reason = 'bad body';
              const [x, y, width, height] = [cursor.u16(reason), cursor.u16(reason), cursor.u16(reason), cursor.u16(reason)];
              return { tag: 'pixels', x, y, width, height, pixels: cursor.take(cursor.left, reason) };
            }
            default:
              return refuse('bad tag');
          }
        }

        /* An event's detail, which ends the record; a text is valid UTF-8 bounded by the record. */
        function detail(cursor: Cursor): Detail {
          const reason = 'bad detail';
          const tag = DETAILS[cursor.u8(reason)] ?? refuse(reason);
          let read: Detail;
          switch (tag) {
            case 'none':
              read = { tag };
              break;
            case 'boolean':
              read = { tag, value: readBoolean(cursor, reason) };
              break;
            case 'integer':
              read = { tag, value: cursor.u32(reason) | 0 };
              break;
            case 'text':
              read = { tag, value: text(cursor, 4, OP_MAX, reason) };
              break;
          }
          if (cursor.left !== 0) refuse(reason);
          return read;
        }
      TS
    end
  end
end
