# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # A field of an input record, in wire order after the tag: its name and the
    # root scalar or enum it carries. The type's base integer is its width on
    # the wire, and a scalar's range or an enum's members are what it admits.
    InputField = Struct.new(:name, :type, keyword_init: true) do
      def size = type.size
    end
    # A kind of record: its tag byte on the wire, and its decoded term, the
    # atom NAME followed by the atoms WORDS and then its fields' values, or the
    # bare NAME when it has neither.
    InputRecord = Struct.new(:name, :words, :tag, :fields, keyword_init: true) do
      def body_size = fields.sum(&:size)
    end
    # Every record is SIZE bytes: the tag and the largest kind's fields.
    InputSchema = Struct.new(:records, :size, keyword_init: true)

    # The reader of the one `input` declaration (docs/design-abi.md, "Input
    # records"). It refuses every source the grammar refuses and returns a
    # frozen schema, records in tag order, each field resolved to its root type.
    module Input
      SOURCE = 'abi/formats/input.txt'
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/.freeze
      # A field name has no underscore, so its capitalized variable is its own.
      FIELD_NAME = /\A[a-z][a-z0-9]{0,62}\z/.freeze
      # The tag is one byte; 0 is no kind, so a zeroed record is refused.
      TAGS = (1..255).freeze

      module_function

      # TYPES are the root types by name.
      def validate(declarations, types:)
        return nil if declarations.empty?

        declarations.drop(1).first&.fail!('exactly one input declaration is allowed')
        declaration = declarations.first
        declaration.fail!("the input declaration belongs in #{SOURCE}") unless declaration.line.path == SOURCE
        declaration.fail!('expected input') unless declaration.args.empty?
        records = records(declaration.members, types).sort_by(&:tag)
        declaration.fail!('the input declaration has no record') if records.empty?
        InputSchema.new(records: records, size: 1 + records.map(&:body_size).max)
      end

      # The members grouped as record lines with their four-space field lines.
      def records(members, types)
        groups = members.each_with_object([]) do |line, result|
          line.fail!('an input member is at two spaces and a field at four') unless [2, 4].include?(line.indent)
          if line.indent == 2
            line.fail!("unknown input member #{line.words.first}") unless line.words.first == 'record'
            result << [line, []]
          else
            result.last.last << line
          end
        end
        groups.each_with_object([]) do |(line, children), records|
          line.fail!('expected record NAME TAG [WORD...]') unless line.words.size >= 3
          _, name, tag_word, *words = line.words
          [name, *words].each { |word| line.fail!("invalid input record word #{word.inspect}") unless NAME.match?(word) }
          tag = Syntax.integer(tag_word, line: line)
          line.fail!("input tag #{tag} is outside #{TAGS}") unless TAGS.cover?(tag)
          line.fail!("duplicate input tag #{tag}") if records.any? { |record| record.tag == tag }
          distinct!(line, name, words, records)
          records << InputRecord.new(name: name, words: words, tag: tag, fields: fields(children, types))
        end
      end

      # Kinds that share a name have as many words and differ in them, so their
      # terms differ in an atom before any field and each term has one kind.
      def distinct!(line, name, words, records)
        records.select { |record| record.name == name }.each do |record|
          line.fail!("record #{name} has #{words.size} words where an earlier one has #{record.words.size}") \
            unless record.words.size == words.size
          line.fail!("record #{[name, *words].join(' ')} repeats an earlier one") if record.words == words
        end
      end

      def fields(lines, types)
        lines.each_with_object([]) do |line, fields|
          line.fail!('expected field NAME @TYPE') unless line.words.size == 3 && line.words.first == 'field'
          _, name, reference = line.words
          line.fail!("invalid input field name #{name.inspect}") unless FIELD_NAME.match?(name)
          line.fail!("duplicate input field #{name}") if fields.any? { |field| field.name == name }
          fields << InputField.new(name: name, type: field_type(line, reference, types))
        end
      end

      # A root scalar, or a root enum that is not a flags type.
      def field_type(line, reference, types)
        type = reference.start_with?('@') ? types[reference.delete_prefix('@')] : nil
        admitted = type.is_a?(ScalarType) || (type.is_a?(EnumType) && !type.flags)
        line.fail!("#{reference} is not a root scalar or enum") unless admitted
        line.fail!("#{reference} has an alignment constraint") if type.is_a?(ScalarType) && type.multiple != 1
        # A type's name and an enum's members become Erlang names, so each is a plain identifier.
        names = [type.name, *(type.is_a?(EnumType) ? type.members.keys : [])]
        names.each { |name| line.fail!("#{reference}: #{name} is not a plain identifier") unless NAME.match?(name) }
        type
      end
    end
  end
end
