# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # A field of a draw message, in wire order. TYPE is a key of
    # Draw::FIXED_TYPES or one of Draw::VARIABLE_TYPES. COUNT is the index,
    # within the message's fields, of the u16 field that counts a points or
    # indices field's items; ID and RECT are the indices of the id and
    # rectangle fields a pixels or compressed field depends on. COUNTED marks
    # a count field: the field that names it carries its items, so the
    # decoded message leaves it out.
    DrawField = Struct.new(:name, :type, :count, :id, :rect, :counted, keyword_init: true) do
      def width = Draw::FIXED_TYPES[type]
      def fixed? = !width.nil?
    end
    # A message: its name, which is the decoded term's tag, its letter on the
    # wire, and its fields after the letter.
    DrawMessage = Struct.new(:name, :letter, :fields, keyword_init: true) do
      # The fields the decoded term carries, in wire order.
      def carried = fields.reject(&:counted)
    end
    DrawSchema = Struct.new(:version, :messages, keyword_init: true)

    # The reader of the one `draw VERSION` declaration (docs/design-abi.md,
    # "Draw format"). It refuses every source the grammar refuses and returns
    # a frozen schema with every reference resolved to a field index.
    module Draw
      SOURCE = 'abi/formats/draw.txt'
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/.freeze
      # A letter is one printable ASCII byte other than the quotes and the backslash.
      LETTER = /\A[!#-&(-\[\]-~]\z/.freeze
      # Erlang's reserved words, which a message name would emit as a bare atom.
      RESERVED = %w[after and andalso band begin bnot bor bsl bsr bxor case catch cond div else end fun if let maybe
                    not of or orelse receive rem try when xor].freeze
      # A field's position is a u8 in the C table.
      FIELDS_MAX = 255
      # The fixed field types and their sizes: unsigned and signed integers,
      # an image id, a point of two 32-bit coordinates and a rectangle of four.
      FIXED_TYPES = { 'u8' => 1, 'u16' => 2, 'u32' => 4, 'i32' => 4, 'id' => 4, 'point' => 8, 'rect' => 16 }.freeze
      # The fields whose length the message itself gives: coded points, COUNT
      # + 1 of them; u16 glyph indices, COUNT of them; and the pixels of an id's
      # rectangle, raw or in image(6)'s compressed form.
      VARIABLE_TYPES = %w[points indices pixels compressed].freeze

      module_function

      def validate(declarations)
        return nil if declarations.empty?

        declarations.drop(1).first&.fail!('exactly one draw declaration is allowed')
        declaration = declarations.first
        declaration.fail!("the draw declaration belongs in #{SOURCE}") unless declaration.line.path == SOURCE
        declaration.fail!('expected draw VERSION') unless declaration.line.tokens.size == 2
        version = Syntax.integer(declaration.args.first, line: declaration.line)
        declaration.fail!('draw version must be positive and fit 32 bits') unless version.between?(1, 0xffffffff)
        DrawSchema.new(version: version, messages: messages(declaration.members))
      end

      # The members grouped as message lines with their four-space field lines.
      def messages(members)
        groups = members.each_with_object([]) do |line, result|
          line.fail!('a draw member is at two spaces and a field at four') unless [2, 4].include?(line.indent)
          if line.indent == 2
            line.fail!("unknown draw member #{line.words.first}") unless line.words.first == 'message'
            result << [line, []]
          else
            line.fail!('a field line belongs under a message') if result.empty?
            result.last.last << line
          end
        end
        names = {}
        letters = {}
        groups.map do |line, children|
          line.fail!('expected message NAME LETTER') unless line.words.size == 3
          _, name, letter = line.words
          line.fail!("invalid draw message name #{name.inspect}") unless NAME.match?(name) && !RESERVED.include?(name)
          line.fail!("message #{name} has more than #{FIELDS_MAX} fields") if children.size > FIELDS_MAX
          line.fail!("duplicate draw message #{name}") if names.key?(name)
          line.fail!("invalid draw letter #{letter.inspect}") unless LETTER.match?(letter)
          line.fail!("duplicate draw letter #{letter}") if letters.key?(letter)
          names[name] = letters[letter] = true
          DrawMessage.new(name: name, letter: letter, fields: fields(children))
        end
      end

      def fields(lines)
        lines.each_with_object([]) do |line, fields|
          line.fail!('expected field NAME TYPE [REFERENCES]') unless line.words.first == 'field' && line.words.size >= 3
          name = line.words[1]
          line.fail!("invalid draw field name #{name.inspect}") unless NAME.match?(name)
          line.fail!("duplicate draw field #{name}") if fields.any? { |field| field.name == name }
          fields << field(line, name, line.words.drop(2), fields)
        end
      end

      def field(line, name, words, earlier)
        case words
        in [type] if FIXED_TYPES.key?(type) then DrawField.new(name: name, type: type, counted: false)
        in [('points' | 'indices') => type, count]
          index = reference(line, count, 'u16', earlier)
          line.fail!("count #{count} already counts a field") if earlier[index].counted
          earlier[index] = earlier[index].dup.tap { |field| field.counted = true }
          DrawField.new(name: name, type: type, count: index, counted: false)
        in [('pixels' | 'compressed') => type, id, rect]
          DrawField.new(name: name, type: type, id: reference(line, id, 'id', earlier),
                        rect: reference(line, rect, 'rect', earlier), counted: false)
        else line.fail!("unknown draw field type #{words.join(' ')}")
        end
      end

      def reference(line, name, type, earlier)
        index = earlier.index { |field| field.name == name }
        line.fail!("#{name} is not an earlier #{type} field") unless index && earlier[index].type == type
        index
      end
    end
  end
end
