# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_emit_packed'

module Erx
  module ABI
    # Emits erx_abi_layout, the typed codec of every fixed wire_le layout
    # (docs/design-abi.md, "Layouts in Erlang"), on erx_abi_packed's model.
    # Each layout has a decoder of its own, decode_<layout>/1: a binary
    # pattern of exactly the layout's size. record/2 dispatches a layout's
    # name to its decoder, and a nested layout's field calls the nested
    # decoder directly, so no decoder recurses through record/2, whose result
    # is the union of every layout's map: Dialyzer would iterate that union
    # around the recursion, which grows with the number of layouts. encode/2
    # may recurse through itself, since its result is always a binary. Each
    # layout is one clause of encode/2, and a nested layout is a nested map.
    #
    # Beyond erx_abi_packed's shapes, an enum field decodes to
    # its member's atom and a flags field to the ordset of its bit names, both
    # through erx_abi_enums:name/2, so no input creates an atom; a signed
    # integer is read signed; and the codec refuses what the layout does not
    # admit: padding that is not zeros, a scalar outside its range, and bytes
    # of a fixed value that differ from it. Each layout is also a -type of its
    # map, field for field under its declared names.
    #
    # decode/2 has one failure path: a refused value throws {?MODULE, Error}
    # out of a decoder, and decode/2 catches it once.
    module LayoutEmitter
      ERLANG_PATH = 'erlang/apps/erx/src/generated/erx_abi_layout.erl'
      # The atoms of decode/2's own errors; no checked type may share one.
      OWN_ERRORS = %w[size padding].freeze

      # A layout's padding run: its offset and its byte count.
      Padding = Data.define(:offset, :bytes) do
        def variable = "Padding#{offset}"
      end

      module_function

      def outputs(schema)
        layouts = schema.type_order.map { |name| schema.types.fetch(name) }
                        .select { |type| type.is_a?(Layout) && type.storage == 'wire_le' && !type.tail }
        return {} if layouts.empty?

        { ERLANG_PATH => erlang(layouts) }.freeze
      end

      def atom(name) = PackedEmitter.atom(name)
      def variable(field) = PackedEmitter.variable(field)
      def paddings(layout) = layout.padding.map { |offset, bytes| Padding.new(offset:, bytes:) }

      # Every field and padding run in offset order.
      def members(layout) = (layout.fields + paddings(layout)).sort_by(&:offset)

      def check_variables(layout)
        names = layout.fields.map { |field| variable(field) } + paddings(layout).map(&:variable)
        clash = names.tally.find { |name, count| count > 1 || name == PackedEmitter::ELEMENT }
        raise SchemaError, "layout #{layout.name}: members share the variable #{clash.first}" if clash
      end

      # How a field is held in the map: an integer (a scalar checked against
      # its range), a list of integers, a binary (an unsigned byte array or a
      # bytes field, a fixed one checked against its value), a list of
      # binaries, an enum or flags name, a nested map, or a list of maps. An
      # array of a checked type has no shape.
      def shape(field)
        type = field.type
        if field.array? && (type.is_a?(EnumType) || type.is_a?(ScalarType) || (type.is_a?(BytesType) && type.fixed))
          raise SchemaError, "#{field.name}: erx_abi_layout holds no array of #{type.name}"
        end

        case type
        in EnumType then :coded
        in ScalarType then :scalar
        in BytesType if type.fixed then :fixed
        in BytesType then field.array? ? :binaries : :bytes
        in Layout then field.array? ? :layouts : :layout
        in IntegerType if !field.array? then :integer
        in IntegerType if type.size == 1 && !type.signed then :bytes
        in IntegerType then :integers
        end
      end

      def integer(field) = field.type.integer
      def bits(field) = field.type.size * 8

      # An integer segment of a little-endian layout; a byte has no order.
      def segment(value, integer)
        modifiers = [integer.size == 1 ? nil : 'little', integer.signed ? 'signed' : nil].compact
        modifiers.empty? ? "#{value}:#{integer.bits}" : "#{value}:#{integer.bits}/#{modifiers.join('-')}"
      end

      # A fixed value as an Erlang binary: its printable runs quoted, other bytes as numbers.
      def binary_literal(bytes)
        runs = bytes.b.scan(/[\x20-\x7e]+|[^\x20-\x7e]/n).map do |run|
          run.match?(/\A[\x20-\x7e]+\z/n) ? %("#{run.gsub(/[\\"]/) { "\\#{_1}" }}") : run.ord.to_s
        end
        "<<#{runs.join(', ')}>>"
      end

      # The call that checks a field's value against its type, the same in either direction.
      def checked_call(field, value)
        type = field.type
        case shape(field)
        in :scalar then "scalar(#{atom(type.name)}, #{value}, #{type.minimum}, #{type.maximum}, #{type.multiple || 1})"
        in :fixed then "fixed(#{atom(type.name)}, #{value}, #{binary_literal(type.fixed)})"
        end
      end

      def pattern_segment(field)
        return segment(variable(field), integer(field)) if %i[integer scalar coded].include?(shape(field))

        "#{variable(field)}:#{field.size}/binary"
      end

      def decoded_value(field)
        name = variable(field)
        element = PackedEmitter::ELEMENT
        case shape(field)
        in :integer | :bytes then name
        in :scalar | :fixed then checked_call(field, name)
        in :coded then "coded(#{atom(field.type.name)}, #{name})"
        in :integers then "[#{element} || <<#{segment(element, integer(field))}>> <= #{name}]"
        in :binaries then "[#{element} || <<#{element}:#{field.type.size}/binary>> <= #{name}]"
        in :layout then "#{decoder(field.type)}(#{name})"
        in :layouts
          "[#{decoder(field.type)}(#{element})\n          || <<#{element}:#{field.type.size}/binary>> <= #{name}]"
        end
      end

      def encoded_segment(field)
        name = variable(field)
        element = PackedEmitter::ELEMENT
        case shape(field)
        in :integer then segment("(#{checker(integer(field))}(#{name}, #{bits(field)}))", integer(field))
        in :scalar then segment("(#{checked_call(field, name)})", integer(field))
        in :fixed then "(#{checked_call(field, name)})/binary"
        in :coded then segment("(erx_abi_enums:value(#{atom(field.type.name)}, #{name}))", integer(field))
        in :integers
          checked = segment("(#{checker(integer(field))}(#{element}, #{bits(field)}))", integer(field))
          "(<< <<#{checked}>>\n         || #{element} <- count(#{name}, #{field.count}) >>)/binary"
        in :bytes then "(bytes(#{name}, #{field.size}))/binary"
        in :binaries then "(binaries(#{name}, #{field.count}, #{field.type.size}))/binary"
        in :layout then "(encode(#{atom(field.type.name)}, #{name}))/binary"
        in :layouts then "(layouts(#{atom(field.type.name)}, #{name}, #{field.count}))/binary"
        end
      end

      def checker(integer) = integer.signed ? 'sint' : 'uint'

      def wrapped(parts, indent, closing: 0) = PackedEmitter.wrapped(parts, indent, closing: closing)

      # A layout's decoder function, decode_<layout>.
      def decoder(layout) = atom("decode_#{layout.name}")

      # A layout's clause of record/2, which calls its decoder.
      def record_clause(layout) = "record(#{atom(layout.name)}, Bytes) ->\n    #{decoder(layout)}(Bytes)"

      # A layout's decoder: its bytes, and any other binary as a size error.
      def decoder_function(layout)
        name = atom(layout.name)
        segments = members(layout).map do |member|
          member.is_a?(Padding) ? "#{member.variable}:#{member.bytes}/binary" : pattern_segment(member)
        end
        checks = paddings(layout).map { |padding| "    padding(#{name}, #{padding.variable}),\n" }
        values = layout.fields.map { |field| "#{atom(field.name)} => #{decoded_value(field)}" }
        "#{decoder(layout)}(\n       <<#{wrapped(segments, 9, closing: 6)}>>) ->\n" \
          "#{checks.join}    #\{#{values.join(",\n      ")}};\n" \
          "#{decoder(layout)}(_Bytes) ->\n    fail({size, #{name}})."
      end

      def encode_clause(layout)
        keys = layout.fields.map { |field| "#{atom(field.name)} := #{variable(field)}" }
        segments = members(layout).map do |member|
          member.is_a?(Padding) ? "0:#{member.bytes * 8}" : encoded_segment(member)
        end
        "encode(#{atom(layout.name)},\n       #\{#{wrapped(keys, 9, closing: 5)}}) ->\n" \
          "    <<#{segments.join(",\n      ")}>>"
      end

      # A field's type in its layout's map type.
      def field_type(field)
        type = field.type
        case shape(field)
        in :coded then "erx_abi_enums:#{atom(type.name)}()"
        in :scalar then "#{type.minimum}..#{type.maximum}"
        in :fixed | :bytes then "<<_:#{field.size * 8}>>"
        in :binaries then "[<<_:#{type.size * 8}>>]"
        in :layout then "#{atom(type.name)}()"
        in :layouts then "[#{atom(type.name)}()]"
        in :integer then "#{atom(type.name)}()"
        in :integers then "[#{atom(type.name)}()]"
        end
      end

      def layout_type(layout)
        head = "-type #{atom(layout.name)}() ::"
        fields = layout.fields.map { |field| "#{atom(field.name)} := #{field_type(field)}" }
        "#{head}\n    \#{#{fields.join(",\n      ")}}."
      end

      # The integer types the layouts' map types name, each the range of its width.
      def integer_types(layouts)
        integers = layouts.flat_map(&:fields).select { |field| %i[integer integers].include?(shape(field)) }
                          .map(&:type)
        integers.uniq(&:name).sort_by(&:name).map do |integer|
          range = if integer.signed
                    "-#{1 << (integer.bits - 1)}..#{(1 << (integer.bits - 1)) - 1}"
                  else
                    "0..#{(1 << integer.bits) - 1}"
                  end
          "-type #{atom(integer.name)}() :: #{range}."
        end
      end

      # The types whose values decode/2 checks, by name: each is an error's first element.
      def checked_types(layouts)
        checked = layouts.flat_map(&:fields).select { |field| %i[coded scalar fixed].include?(shape(field)) }
        checked.map { |field| atom(field.type.name) }.uniq.sort.tap do |names|
          clash = names & OWN_ERRORS
          raise SchemaError, "type #{clash.first} shares a name with an erx_abi_layout error" unless clash.empty?
        end
      end

      def checked_error(checked)
        return '' if checked.empty?

        "\n               | {#{checked.join("\n                  | ")},\n                  integer() | binary()}"
      end

      HELPERS = {
        'uint' => PackedEmitter::HELPERS.fetch('uint'),
        'sint' => <<~ERLANG,
          sint(Value, Bits) when is_integer(Value), Value >= -(1 bsl (Bits - 1)), Value < 1 bsl (Bits - 1) ->
              Value.
        ERLANG
        'count' => PackedEmitter::HELPERS.fetch('count'),
        'bytes' => PackedEmitter::HELPERS.fetch('bytes'),
        'binaries' => PackedEmitter::HELPERS.fetch('binaries'),
        'layouts' => PackedEmitter::HELPERS.fetch('layouts'),
        'coded' => <<~ERLANG,
          %% An enum or flags field's name; a value its type does not admit fails.
          coded(Type, Value) ->
              case erx_abi_enums:name(Type, Value) of
                  {ok, Name} -> Name;
                  error -> fail({Type, Value})
              end.
        ERLANG
        'scalar' => <<~ERLANG,
          %% A scalar within its range and a multiple of its step; any other fails.
          scalar(_Type, Value, Minimum, Maximum, Multiple)
            when is_integer(Value), Value >= Minimum, Value =< Maximum, Value rem Multiple =:= 0 ->
              Value;
          scalar(Type, Value, _Minimum, _Maximum, _Multiple) ->
              fail({Type, Value}).
        ERLANG
        'fixed' => <<~ERLANG,
          %% Bytes of a fixed value are that value; any other fails.
          fixed(_Type, Expected, Expected) ->
              Expected;
          fixed(Type, Bytes, _Expected) ->
              fail({Type, Bytes}).
        ERLANG
        'padding' => <<~ERLANG
          %% Padding is zeros; any other byte fails.
          padding(Layout, Bytes) ->
              Bits = bit_size(Bytes),
              case Bytes of
                  <<0:Bits>> -> ok;
                  _ -> fail({padding, Layout})
              end.
        ERLANG
      }.freeze

      # The helpers a field of each shape calls beyond erx_abi_packed's, whose
      # SHAPE_HELPERS names the rest; 'uint' stands for the field's checker.
      SHAPE_HELPERS = PackedEmitter::SHAPE_HELPERS.merge(coded: %w[coded], scalar: %w[scalar], fixed: %w[fixed]).freeze

      def helpers(layouts)
        used = layouts.flat_map(&:fields).flat_map do |field|
          SHAPE_HELPERS.fetch(shape(field)).map { |name| name == 'uint' ? checker(integer(field)) : name }
        end
        used << 'padding' if layouts.any? { |layout| !layout.padding.empty? }
        HELPERS.select { |name, _text| used.include?(name) }.values
      end

      def erlang(layouts)
        layouts.each { |layout| check_variables(layout) }
        names = layouts.map { |layout| atom(layout.name) }
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from the wire_le layouts of
          %% abi/erx_abi.txt. Do not edit this file.

          -module(erx_abi_layout).
          -moduledoc """
          The ABI's fixed wire_le layouts as typed maps (docs/design-abi.md,
          "Layouts in Erlang").

          decode/2 turns a layout's bytes into a map of its fields under their
          declared names, and encode/2 the map back into the same bytes. An
          integer field is an integer, an enum field its member's atom, a flags
          field the ordset of its bit names, a nested layout a map, an unsigned
          byte array or a bytes field a binary, and any other array a list. A
          value the layout does not admit is refused, never guessed: an enum
          value no member holds, a flags bit its type does not declare, a scalar
          outside its range, bytes that differ from their fixed value, padding
          that is not zeros, or bytes of another size than the layout's.
          Sentinels, such as an unused slot of zeros, stay as their fields hold
          them: what they mean is their reader's.
          """.
          -export([decode/2, encode/2]).
          -export_type([layout/0, error/0,
                        #{names.map { |name| "#{name}/0" }.join(",\n              ")}]).

          -type layout() :: #{names.join("\n                | ")}.

          -doc """
          Why bytes are refused: {size, Layout}, not the layout's size; {padding,
          Layout}, a padding byte of Layout or a layout it embeds is not zero;
          {Type, Value}, a field of Type holds Value, which its type does not
          admit.
          """.
          -type error() :: {size | padding, layout()}#{checked_error(checked_types(layouts))}.

          #{integer_types(layouts).join("\n")}

          #{layouts.map { |layout| layout_type(layout) }.join("\n\n")}

          -doc """
          The map of a layout's bytes, which must be exactly the layout's size.
          A layout this module does not know is a function_clause error.
          """.
          -spec decode(layout(), binary()) -> {ok, \#{atom() => term()}} | {error, error()}.
          decode(Layout, Bytes) when is_binary(Bytes) ->
              try
                  {ok, record(Layout, Bytes)}
              catch
                  throw:{?MODULE, Error} -> {error, Error}
              end.

          -doc """
          A layout's bytes from a map holding each of its fields; a missing field,
          a value wider than its field or of the wrong length, a value its type
          does not admit, or a name its enum or flags type does not have, is an
          exception. A flags field may list its bit names in any order.
          """.
          -spec encode(layout(), \#{atom() => term()}) -> binary().
          #{layouts.map { |layout| encode_clause(layout) }.join(";\n")}.

          #{layouts.map { |layout| record_clause(layout) }.join(";\n")}.

          #{layouts.map { |layout| decoder_function(layout) }.join("\n\n")}

          fail(Error) ->
              throw({?MODULE, Error}).

          #{helpers(layouts).join("\n")}
        ERLANG
      end
    end
  end
end
