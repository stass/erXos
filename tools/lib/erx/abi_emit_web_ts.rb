# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_typescript'

module Erx
  module ABI
    # Emits web/src/generated/proto.ts, the web client's codec of the web
    # protocol (docs/design-web.md, "The protocol"), the twin of the Erlang
    # codec WebEmitter emits: the message types, the type table both codecs
    # interpret, the limits and the protocol hash, and a fixed decoder and
    # encoder over the table. Field names are camelCase in TypeScript and a
    # union's case is its `tag`; a union of cases without fields is a string.
    module WebTSEmitter
      PATH = 'web/src/generated/proto.ts'

      module_function

      def typescript(web, hash:)
        distinct!(web)
        ts = TypeScript
        [
          ts.header(source: 'abi/protocols/web.txt', summary: <<~TEXT),
            The web protocol's codec (docs/design-web.md, "The protocol"): one
            decoder and one encoder per message union, interpreting TYPES, the
            table of web.txt's types. Integers are little-endian; bytes and texts
            are a u32 length and the bytes; a list is a u32 count and its
            elements; a union is a u8 tag and its case's fields. Every text from
            the machine decodes as a MachineText, whose bytes only the line escape
            and this codec, which keeps the bytes of each text it makes, can read;
            a decimal integer as a bigint;
            a ui.txt record as its bytes, length included, for ui_wire.ts to read.
            Neither direction throws on what it is handed: each returns a value
            or a refusal with its reason.
          TEXT
          "import { MachineText } from '../text.ts';\nimport { Cursor, Refusal, Writer, refuse } from '../wire.ts';\n",
          ts.constant(name: 'PROTOCOL_HASH_HEX', value: ts.string(hash),
                      comment: 'The SHA-256 over web.txt, ui.txt, inspection.txt, terminal.txt and its Unicode data.'),
          web.limits.map { |name, value| ts.constant(name: name.upcase, value: value, comment: "The limit #{name}.") }.join,
          ts.names(constant: 'STOPGAPS', type: 'Stopgap', members: web.stopgaps,
                   comment: "The inspection schema's stopgap reporters, the names a stopgap type admits."),
          types(web),
          table(web),
          CODEC,
          entry_points(web)
        ].join("\n")
      end

      # The TypeScript names the codec declares beside the types.
      CODEC_NAMES = %w[Spec Field Case Decoded Encoded Writer Stopgap MachineText Cursor Refusal].freeze

      # Two web.txt names that map to one TypeScript name would make one
      # type or field hide another, so the mapping must stay injective.
      def distinct!(web)
        names = web.types.keys.map { |name| pascal(name) }
        clash = (names.tally.select { |_, count| count > 1 }.keys + (names & CODEC_NAMES)).first
        raise SchemaError, "web.txt type name #{clash} clashes in TypeScript" if clash

        web.types.each_value do |type|
          groups = type.cases ? type.cases.map(&:fields) : [type.fields || []]
          groups.each do |fields|
            camels = fields.map { |field| camel(field.name) }
            raise SchemaError, "#{type.name}'s fields clash in TypeScript" unless camels.uniq.size == camels.size
          end
        end
      end

      def pascal(name) = name.split('_').map(&:capitalize).join
      def camel(name) = name.split('_').each_with_index.map { |part, index| index.zero? ? part : part.capitalize }.join

      # A TypeScript type per declared type, under the declaration's name.
      def types(web)
        web.types.values.map do |type|
          "export type #{pascal(type.name)} =#{type_body(type)};\n"
        end.join
      end

      def type_body(type)
        case type.form
        when 'integer' then ' number'
        when 'bytes', 'ui_record' then ' Uint8Array'
        when 'text' then ' MachineText'
        when 'digits' then ' bigint'
        when 'stopgap' then ' Stopgap'
        when 'list' then " readonly #{reference(type.element)}[]"
        when 'tuple', 'map' then " #{object(type.fields)}"
        when 'union'
          members = if type.cases.all? { |entry| entry.fields.empty? }
                      type.cases.map { |entry| TypeScript.string(entry.name) }
                    else
                      type.cases.map { |entry| object(entry.fields, tag: entry.name) }
                    end
          members.map { |member| "\n  | #{member}" }.join
        end
      end

      def object(fields, tag: nil)
        members = fields.map { |field| "readonly #{camel(field.name)}: #{reference(field.type)}" }
        members.unshift("readonly tag: #{TypeScript.string(tag)}") if tag
        "{ #{members.join('; ')} }"
      end

      def reference(name) = name == 'boolean' ? 'boolean' : pascal(name)

      def table(web)
        entries = web.types.values.map { |type| [TypeScript.string(type.name), spec(type)] }
        "/* Each type's layout, by its web.txt name. */\nexport const TYPES: ReadonlyMap<string, Spec> = " \
          "#{TypeScript.map(entries, type: 'string, Spec')};\n"
      end

      def spec(type)
        case type.form
        when 'integer'
          "{ form: 'integer', bytes: #{type.bits / 8}, min: #{type.minimum}, max: #{type.maximum} }"
        when 'bytes', 'text', 'digits', 'stopgap', 'ui_record'
          "{ form: '#{type.form}', max: #{type.maximum}, exact: #{type.exact ? 'true' : 'false'} }"
        when 'list' then "{ form: 'list', element: #{TypeScript.string(type.element)}, max: #{type.maximum} }"
        when 'tuple', 'map' then "{ form: 'struct', fields: #{fields(type.fields)} }"
        when 'union'
          cases = type.cases.map do |entry|
            "{ name: #{TypeScript.string(entry.name)}, tag: #{entry.tag}, fields: #{fields(entry.fields)}, " \
              "recursive: #{entry.recursive} }"
          end
          enumeration = type.cases.all? { |entry| entry.fields.empty? }
          "{\n    form: 'union',\n    depth: #{type.depth || 0},\n    enumeration: #{enumeration},\n    " \
            "cases: [\n      #{cases.join(",\n      ")},\n    ],\n  }"
        end
      end

      def fields(list)
        "[#{list.map { |field| "{ name: #{TypeScript.string(camel(field.name))}, type: #{TypeScript.string(field.type)} }" }.join(', ')}]"
      end

      def entry_points(web)
        web.messages.map do |name|
          type = pascal(name)
          max = web.types.fetch(name).message
          <<~TS
            /* Decodes one whole #{name} message of at most #{max} bytes. */
            export function decode#{type}(bytes: Uint8Array): Decoded<#{type}> {
              return decode(#{TypeScript.string(name)}, #{max}, bytes) as Decoded<#{type}>;
            }

            /* Encodes one #{name} message, refusing what decode#{type} would refuse. */
            export function encode#{type}(message: #{type}): Encoded {
              return encode(#{TypeScript.string(name)}, #{max}, message);
            }
          TS
        end.join("\n")
      end

      CODEC = <<~'TS'
        /* The layout of one type: what TYPES holds. depth is 0 for a union without one. */
        export type Spec =
          | { readonly form: 'boolean' }
          | { readonly form: 'integer'; readonly bytes: 1 | 2 | 4; readonly min: number; readonly max: number }
          | { readonly form: 'bytes' | 'text' | 'digits' | 'stopgap' | 'ui_record'; readonly max: number; readonly exact: boolean }
          | { readonly form: 'list'; readonly element: string; readonly max: number }
          | { readonly form: 'struct'; readonly fields: readonly Field[] }
          | {
              readonly form: 'union';
              readonly depth: number;
              readonly enumeration: boolean;
              readonly cases: readonly Case[];
            };

        export interface Field {
          readonly name: string;
          readonly type: string;
        }

        export interface Case {
          readonly name: string;
          readonly tag: number;
          readonly fields: readonly Field[];
          readonly recursive: boolean;
        }

        export type Decoded<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly reason: string };
        export type Encoded = { readonly ok: true; readonly bytes: Uint8Array } | { readonly ok: false; readonly reason: string };

        /* The protocol hash as bytes, a fresh copy each call. */
        export function protocolHash(): Uint8Array {
          return Uint8Array.from(PROTOCOL_HASH_HEX.match(/../g) ?? [], (pair) => parseInt(pair, 16));
        }

        const BOOLEAN: Spec = Object.freeze({ form: 'boolean' });
        const DIGITS = /^(0|-?[1-9][0-9]*)$/;

        /*
         * The bytes of each MachineText this codec made, so the encoder can write
         * one back without any outlet on MachineText itself.
         */
        const TEXTS = new WeakMap<MachineText, Uint8Array>();

        /* A MachineText of BYTES the encoder can write: what the decoder returns. */
        export function machineText(bytes: Uint8Array): MachineText {
          const text = new MachineText(bytes);
          TEXTS.set(text, Uint8Array.prototype.slice.call(bytes));
          return text;
        }

        function specOf(name: string): Spec {
          if (name === 'boolean') return BOOLEAN;
          const spec = TYPES.get(name);
          if (spec === undefined) throw new Error(`proto.ts: no type ${name}`);
          return spec;
        }

        function ascii(bytes: Uint8Array): string {
          return String.fromCharCode(...bytes);
        }

        function asciiBytes(text: string): Uint8Array {
          return Uint8Array.from(text, (char) => char.charCodeAt(0));
        }

        function decode(message: string, max: number, bytes: Uint8Array): Decoded<unknown> {
          if (bytes.length > max) return { ok: false, reason: `too_long ${message}` };
          const cursor = new Cursor(bytes, 0, bytes.length);
          try {
            const value = read(message, cursor, 1);
            if (cursor.left !== 0) return { ok: false, reason: `trailing ${message}` };
            return { ok: true, value };
          } catch (error) {
            if (error instanceof Refusal) return { ok: false, reason: error.reason };
            throw error;
          }
        }

        /* A u32 length of at most MAX, then that many bytes. */
        function sized(cursor: Cursor, max: number, name: string): Uint8Array {
          const length = cursor.u32(`truncated ${name}`);
          if (length > max) refuse(`too_long ${name}`);
          return cursor.take(length, `truncated ${name}`);
        }

        /*
         * The value of type NAME at the cursor, LEVEL deep in the depth union;
         * a depth union's recursive case reads its fields a level deeper.
         */
        function read(name: string, cursor: Cursor, level: number): unknown {
          const spec = specOf(name);
          switch (spec.form) {
            case 'integer': {
              const reason = `truncated ${name}`;
              const value = spec.bytes === 1 ? cursor.u8(reason) : spec.bytes === 2 ? cursor.u16(reason) : cursor.u32(reason);
              if (value < spec.min || value > spec.max) refuse(`bad_value ${name}`);
              return value;
            }
            case 'boolean': {
              const value = cursor.u8(`truncated ${name}`);
              if (value > 1) refuse(`bad_value ${name}`);
              return value === 1;
            }
            case 'bytes': {
              const bytes = sized(cursor, spec.max, name);
              if (spec.exact && bytes.length !== spec.max) refuse(`bad_value ${name}`);
              return bytes;
            }
            case 'text':
              return machineText(sized(cursor, spec.max, name));
            case 'digits': {
              const text = ascii(sized(cursor, spec.max, name));
              if (!DIGITS.test(text)) refuse(`bad_value ${name}`);
              return BigInt(text);
            }
            case 'stopgap': {
              const text = ascii(sized(cursor, spec.max, name));
              const stopgap = STOPGAPS.find((entry) => entry === text);
              if (stopgap === undefined) refuse(`bad_value ${name}`);
              return stopgap;
            }
            case 'ui_record': {
              const length = cursor.u32(`truncated ${name}`);
              if (length < 1 || length > spec.max) refuse(`bad_value ${name}`);
              const body = cursor.take(length, `truncated ${name}`);
              const record = new Uint8Array(4 + length);
              record.set([length & 0xff, (length >>> 8) & 0xff, (length >>> 16) & 0xff, length >>> 24], 0);
              record.set(body, 4);
              return record;
            }
            case 'list': {
              // Every element takes at least one byte, so a count the bytes
              // cannot hold is refused before any element is read.
              const count = cursor.u32(`truncated ${name}`);
              if (count > spec.max) refuse(`too_many ${name}`);
              if (count > cursor.left) refuse(`truncated ${name}`);
              const items: unknown[] = [];
              for (let index = 0; index < count; index++) items.push(read(spec.element, cursor, level));
              return Object.freeze(items);
            }
            case 'struct':
              return Object.freeze(readFields(spec.fields, cursor, level, {}));
            case 'union': {
              const tag = cursor.u8(`truncated ${name}`);
              const entry = spec.cases.find((candidate) => candidate.tag === tag);
              if (entry === undefined || (entry.recursive && level >= spec.depth)) refuse(`bad_tag ${name}`);
              if (spec.enumeration) return entry.name;
              return Object.freeze(readFields(entry.fields, cursor, entry.recursive ? level + 1 : level, { tag: entry.name }));
            }
          }
        }

        function readFields(fields: readonly Field[], cursor: Cursor, level: number, value: Record<string, unknown>): Record<string, unknown> {
          for (const field of fields) value[field.name] = read(field.type, cursor, level);
          return value;
        }

        function encode(message: string, max: number, value: unknown): Encoded {
          const writer = new Writer(max, `too_long ${message}`);
          try {
            write(message, value, writer, 1);
            return { ok: true, bytes: writer.written() };
          } catch (error) {
            if (error instanceof Refusal) return { ok: false, reason: error.reason };
            throw error;
          }
        }

        function isRecord(value: unknown): value is Record<string, unknown> {
          return typeof value === 'object' && value !== null && !Array.isArray(value) && !(value instanceof Uint8Array);
        }

        function write(name: string, value: unknown, writer: Writer, level: number): void {
          const spec = specOf(name);
          const bad = `bad_term ${name}`;
          switch (spec.form) {
            case 'integer':
              if (typeof value !== 'number' || !Number.isInteger(value) || value < spec.min || value > spec.max) refuse(bad);
              writer.integer(spec.bytes, value);
              return;
            case 'boolean':
              if (typeof value !== 'boolean') refuse(bad);
              writer.integer(1, value ? 1 : 0);
              return;
            case 'bytes':
              if (!(value instanceof Uint8Array) || value.length > spec.max || (spec.exact && value.length !== spec.max)) refuse(bad);
              writer.sized(value);
              return;
            case 'text': {
              const bytes = value instanceof MachineText ? TEXTS.get(value) : undefined;
              if (bytes === undefined || bytes.length > spec.max) refuse(bad);
              writer.sized(bytes);
              return;
            }
            case 'digits': {
              if (typeof value !== 'bigint') refuse(bad);
              const text = value.toString();
              if (text.length > spec.max) refuse(bad);
              writer.sized(asciiBytes(text));
              return;
            }
            case 'stopgap':
              if (typeof value !== 'string' || !STOPGAPS.some((entry) => entry === value)) refuse(bad);
              writer.sized(asciiBytes(value));
              return;
            case 'ui_record': {
              if (!(value instanceof Uint8Array) || value.length < 5) refuse(bad);
              const length = value.length - 4;
              const declared = (value[0]! | (value[1]! << 8) | (value[2]! << 16) | (value[3]! << 24)) >>> 0;
              if (declared !== length || length > spec.max) refuse(bad);
              writer.put(value);
              return;
            }
            case 'list':
              if (!Array.isArray(value) || value.length > spec.max) refuse(bad);
              writer.integer(4, value.length);
              for (const item of value) write(spec.element, item, writer, level);
              return;
            case 'struct':
              if (!isRecord(value)) refuse(bad);
              writeFields(spec.fields, value, writer, level);
              return;
            case 'union': {
              const caseName = spec.enumeration ? value : isRecord(value) ? value['tag'] : undefined;
              const entry = spec.cases.find((candidate) => candidate.name === caseName);
              if (entry === undefined || (entry.recursive && level >= spec.depth)) refuse(bad);
              writer.integer(1, entry.tag);
              if (!spec.enumeration) writeFields(entry.fields, value as Record<string, unknown>, writer, entry.recursive ? level + 1 : level);
              return;
            }
          }
        }

        function writeFields(fields: readonly Field[], value: Record<string, unknown>, writer: Writer, level: number): void {
          for (const field of fields) {
            if (!Object.hasOwn(value, field.name)) refuse(`bad_term ${field.type}`);
            write(field.type, value[field.name], writer, level);
          }
        }
      TS
    end
  end
end
