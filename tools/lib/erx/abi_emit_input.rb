# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_input'
require_relative 'abi_emit_inspection'

module Erx
  module ABI
    # Emits erx_input_codec from the `input` declaration (docs/design-abi.md,
    # "Input records"): the type of a driver's record, its bounds check valid/1,
    # and the reader and writer of its binary form. Each kind of record is one
    # clause of each function, a binary pattern of the fixed record size whose
    # fields have their types' widths, so a read never runs past the bytes it
    # is given; each field's bounds are its root scalar's range or its root
    # enum's members, checked by the one is_TYPE function valid/1 calls.
    module InputEmitter
      ERLANG_PATH = 'erlang/apps/erx/src/generated/erx_input_codec.erl'
      # The column the generated lines aim for, as the Erlang style guide asks.
      COLUMNS = 80

      module_function

      def outputs(schema)
        return {} unless schema.input_records

        { ERLANG_PATH => erlang(schema.input_records) }.freeze
      end

      # An atom as the other Erlang emitters write one, quoted only where it must be.
      def atom(name) = InspectionEmitter.atom(name)

      # A field's variable: its name, which has no underscore, capitalized.
      def variable(field) = field.name.capitalize

      def enum?(field) = field.type.is_a?(EnumType)

      # The term of a record: its leading atoms, then each field as the block
      # renders it; the bare name when it has neither words nor fields.
      def term(record, &field)
        return atom(record.name) if record.words.empty? && record.fields.empty?

        "{#{[*[record.name, *record.words].map { |word| atom(word) }, *record.fields.map(&field)].join(', ')}}"
      end

      # A field's segment of a binary: VALUE at the width and signedness of
      # the field's base type, little-endian.
      def segment(field, value)
        base = field.type.integer
        flags = [(base.size > 1 ? 'little' : nil), (base.signed ? 'signed' : nil)].compact
        flags.empty? ? "#{value}:#{base.bits}" : "#{value}:#{base.bits}/#{flags.join('-')}"
      end

      # The tag, the fields as the block renders each, and the zero bytes to
      # the record size.
      def segments(record, size, &field)
        padding = (size - 1 - record.body_size) * 8
        [record.tag.to_s, *record.fields.map(&field), *(padding.zero? ? [] : ["0:#{padding}"])]
      end

      def types(input) = input.records.flat_map { |record| record.fields.map(&:type) }.uniq(&:name)

      def members(type) = type.members.sort_by { |_member, value| value }

      def erlang_type(type)
        return "#{type.minimum}..#{type.maximum}" if type.is_a?(ScalarType)

        members(type).map { |member, _value| atom(member) }.join(' | ')
      end

      # The parts of a tuple joined at ", ", wrapped to COLUMNS beneath the
      # first part, which starts at column START.
      def wrapped(parts, start)
        lines = parts.each_with_object([+'']) do |part, result|
          piece = result.last.empty? ? part : ", #{part}"
          if !result.last.empty? && start + result.last.size + piece.size + 1 > COLUMNS
            result.last << ','
            result << part.dup
          else
            result.last << piece
          end
        end
        lines.join("\n#{' ' * start}")
      end

      def record_type(input)
        alternatives = input.records.map do |record|
          next atom(record.name) if record.words.empty? && record.fields.empty?

          heads = [record.name, *record.words].map { |word| atom(word) }
          fields = record.fields.map { |field| "#{variable(field)} :: #{field.type.name}()" }
          "{#{wrapped([*heads, *fields], 19)}}"
        end
        "-type record() :: #{alternatives.join("\n                | ")}."
      end

      def decode_clauses(input)
        input.records.map do |record|
          pattern = segments(record, input.size) { |field| segment(field, variable(field)) }
          value = term(record) do |field|
            enum?(field) ? "#{field.type.name}_member(#{variable(field)})" : variable(field)
          end
          "record(<<#{pattern.join(', ')}>>) ->\n    checked(#{value})"
        end + ['record(_Bytes) -> error']
      end

      def encode_clauses(input)
        input.records.map do |record|
          bytes = segments(record, input.size) do |field|
            enum?(field) ? segment(field, "(#{field.type.name}_value(#{variable(field)}))") : segment(field, variable(field))
          end
          "bytes(#{term(record) { |field| variable(field) }}) ->\n    <<#{bytes.join(', ')}>>"
        end
      end

      def valid_clauses(input)
        input.records.map do |record|
          checks = record.fields.map { |field| "is_#{field.type.name}(#{variable(field)})" }
          body = checks.empty? ? 'true' : checks.join(' andalso ')
          body = checks.join(" andalso\n        ") if body.size + 4 > COLUMNS
          "valid(#{term(record) { |field| variable(field) }}) ->\n    #{body}"
        end + ['valid(_Term) -> false']
      end

      # is_TYPE/1 for a scalar's range or an enum's members, and for an enum
      # TYPE_value/1 and TYPE_member/1 between its members and their numbers.
      def type_functions(input)
        types(input).map { |type| type.is_a?(ScalarType) ? scalar_functions(type) : enum_functions(type) }
      end

      def scalar_functions(type)
        <<~ERLANG.chomp
          is_#{type.name}(Value) ->
              is_integer(Value) andalso Value >= #{type.minimum} andalso Value =< #{type.maximum}.
        ERLANG
      end

      def enum_functions(type)
        name = type.name
        atoms = members(type).map { |member, _value| atom(member) }
        values = members(type).map { |member, value| "#{name}_value(#{atom(member)}) -> #{value}" }
        numbers = members(type).map { |member, value| "#{name}_member(#{value}) -> #{atom(member)}" }
        <<~ERLANG.chomp
          is_#{name}(Value) -> lists:member(Value, [#{atoms.join(', ')}]).

          #{values.join(";\n")}.

          %% A number no member has stays a number, which no is_ function admits.
          #{numbers.join(";\n")};
          #{name}_member(Value) -> Value.
        ERLANG
      end

      def erlang(input)
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from abi/formats/input.txt.
          %% Do not edit this file.

          -module(erx_input_codec).
          -moduledoc """
          A driver's record (docs/design-display.md, "Input events") and its
          binary form (docs/design-abi.md, "Input records"), in which a driver
          in another domain serves its device's records as a file. Every record
          is #{input.size} bytes: its tag, its fields in order, little-endian, and zero
          bytes to that size. valid/1 holds a term to the bounds of record();
          decode/1 reads a stream's bytes and drops, and counts, each record
          whose tag, padding or field is outside them, so a bad record costs only
          itself; encode/1 writes one record. The decoder makes no atom.
          """.
          -export([size/0, decode/1, encode/1, valid/1]).
          -export_type([record/0]).

          %% The design names a driver's record record(), as "Input events" spells it.
          -compile({nowarn_redefined_builtin_type, {record, 0}}).

          #{types(input).map { |type| "-type #{type.name}() :: #{erlang_type(type)}." }.join("\n")}
          #{record_type(input)}

          -define(SIZE, #{input.size}).

          -doc "The size of every record, in bytes.".
          -spec size() -> pos_integer().
          size() -> ?SIZE.

          -doc """
          The records of a stream's bytes, in order, with the number dropped, and
          the bytes after the last whole record, fewer than size/0.
          """.
          -spec decode(binary()) ->
                    {[record()], Dropped :: non_neg_integer(), Rest :: binary()}.
          decode(Bytes) -> decode(Bytes, [], 0).

          decode(<<Bytes:?SIZE/binary, Rest/binary>>, Records, Dropped) ->
              case record(Bytes) of
                  {ok, Record} -> decode(Rest, [Record | Records], Dropped);
                  error -> decode(Rest, Records, Dropped + 1)
              end;
          decode(Rest, Records, Dropped) ->
              {lists:reverse(Records), Dropped, Rest}.

          #{decode_clauses(input).join(";\n")}.

          checked(Record) ->
              case valid(Record) of
                  true -> {ok, Record};
                  false -> error
              end.

          -doc "One record's bytes; a term outside record() is badarg.".
          -spec encode(record()) -> binary().
          encode(Record) ->
              valid(Record) orelse error(badarg, [Record]),
              bytes(Record).

          #{encode_clauses(input).join(";\n")}.

          -doc "Whether a term is a record within the bounds of record().".
          -spec valid(term()) -> boolean().
          #{valid_clauses(input).join(";\n")}.

          #{type_functions(input).join("\n\n")}
        ERLANG
      end
    end
  end
end
