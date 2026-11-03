# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'core_archive'
require_relative 'error'
require_relative 'runner'

module Erx
  class StackProofError < Error; end

  # Readers of the two declaration files the stack proof takes besides the
  # call graph (docs/design-kernel.md#stack-proof,
  # docs/design-stopgap.md, "The stack proof"):
  #
  # * kernel/stack_fiasco.txt, the C17 cores' share of Fiasco's thread
  #   block: the block's size, one allowance per entry role, the entries the
  #   tick hook calls, and the declared stack cost of each function outside
  #   the cores that a core calls (the erx_effect_* functions, Fiasco's
  #   memcpy and memset), which the proof counts as leaves;
  # * kernel/stack_targets.txt, the functions each indirect call or branch
  #   may reach, by the name of the function that holds it.
  #
  # Both are line files: a keyword and its fields separated by blanks, and a
  # comment from '#' to the end of the line. Each reader is pure, accepts
  # each keyword only in its one shape, and refuses anything else with the
  # file and line, so a typo stops the proof instead of dropping a rule.
  module StackProofInput
    MAX_FILE_BYTES = 64 * 1024
    MAX_DECLARED_BYTES = 1 << 20
    IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]{0,1023}\z/
    BYTES = /\A(?:0|[1-9][0-9]{0,6})\z/
    # The only functions outside the cores a core may call: the undefined
    # symbols the cores' archive is allowed to keep (docs/design-stopgap.md,
    # "Build"). A leaf of any other name would make a Fiasco call free.
    LEAF_NAME = CoreArchive::UNDEFINED
    # The roles an entry can play, each with its own allowance, and the
    # name the report gives the entries of each: an entry called on a
    # thread's kernel path, and one the tick hook calls.
    ROLES = { 'call' => 'call entries', 'tick' => 'tick hook entries' }.freeze

    # leaves maps each declared function name to its cost in bytes;
    # allowances maps each role to its bytes; tick_entries lists the
    # entries the tick hook calls.
    Budget = Data.define(:block_bytes, :allowances, :tick_entries, :leaves)
    # callers maps the name of each function that holds an indirect call or
    # branch to the names its sites may reach.
    Targets = Data.define(:callers)

    module_function

    def budget(text, path:)
      declarations = fields(text, path: path).group_by { |field| field.words.first }
      unknown = declarations.keys - %w[block allowance tick leaf]
      field_error(declarations.fetch(unknown.first).first, "unknown declaration #{unknown.first}") unless unknown.empty?
      block = single(declarations, 'block', path: path) { |field| byte_count(field, field.words.last, minimum: 1) }
      Budget.new(block_bytes: block,
                 allowances: allowances(declarations.fetch('allowance', []), block: block, path: path),
                 tick_entries: tick_entries(declarations.fetch('tick', []), path: path),
                 leaves: leaves(declarations.fetch('leaf', [])))
    end

    def targets(text, path:)
      callers = fields(text, path: path).each_with_object({}) do |field, table|
        keyword, caller, *reached = field.words
        field_error(field, "unknown declaration #{keyword}") unless keyword == 'indirect'
        field_error(field, 'indirect needs a function and at least one target') if reached.empty?
        [caller, *reached].each { |name| identifier(field, name) }
        field_error(field, "#{caller} is declared twice") if table.key?(caller)
        field_error(field, "#{caller} lists a target twice") unless reached.uniq == reached
        table[caller] = reached.freeze
      end
      Targets.new(callers: callers.freeze)
    end

    # One declaration: its words and where it was read.
    Field = Data.define(:path, :line, :words)

    def fields(text, path:)
      unless text.bytesize <= MAX_FILE_BYTES && text.b.match?(/\A[\x20-\x7e\t\n]*\z/n)
        raise StackProofError, "stack proof: #{Terminal.escape(path)}: not a printable ASCII file of at most " \
                               "#{MAX_FILE_BYTES} bytes"
      end
      text.split("\n").each_with_index.filter_map do |line, index|
        words = line.sub(/#.*/, '').split
        Field.new(path: path, line: index + 1, words: words.freeze) unless words.empty?
      end
    end

    def single(declarations, keyword, path:)
      found = declarations.fetch(keyword, [])
      raise StackProofError, "stack proof: #{Terminal.escape(path)}: no #{keyword} declaration" if found.empty?
      field_error(found[1], "#{keyword} is declared twice") if found.length > 1
      field_error(found.first, "#{keyword} takes one value") unless found.first.words.length == 2
      yield found.first
    end

    def allowances(found, block:, path:)
      table = found.each_with_object({}) do |field, roles|
        field_error(field, 'allowance takes a role and a byte count') unless field.words.length == 3
        _keyword, role, size = field.words
        field_error(field, "unknown role #{role}; the roles are #{ROLES.keys.join(' and ')}") unless ROLES.key?(role)
        field_error(field, "the #{role} allowance is declared twice") if roles.key?(role)
        bytes = byte_count(field, size, minimum: 1)
        field_error(field, "the #{role} allowance exceeds the #{block}-byte block") if bytes > block
        roles[role] = bytes
      end
      missing = ROLES.keys - table.keys
      raise StackProofError, "stack proof: #{Terminal.escape(path)}: no #{missing.first} allowance" unless missing.empty?
      table.freeze
    end

    def tick_entries(found, path:)
      raise StackProofError, "stack proof: #{Terminal.escape(path)}: no tick entry" if found.empty?

      found.each_with_object([]) do |field, names|
        field_error(field, 'tick takes one function name') unless field.words.length == 2
        name = identifier(field, field.words[1])
        field_error(field, "tick entry #{name} is declared twice") if names.include?(name)
        names << name
      end.freeze
    end

    def leaves(found)
      found.each_with_object({}) do |field, table|
        field_error(field, 'leaf takes a function name and a byte count') unless field.words.length == 3
        _keyword, name, cost = field.words
        field_error(field, "leaf #{name} is no erx_effect_* function, memcpy or memset") unless LEAF_NAME.match?(name)
        field_error(field, "leaf #{name} is declared twice") if table.key?(name)
        table[name] = byte_count(field, cost, minimum: 0)
      end.freeze
    end

    def identifier(field, word)
      field_error(field, "#{word} is not a C identifier") unless IDENTIFIER.match?(word)
      word
    end

    def byte_count(field, word, minimum:)
      value = Integer(word, 10) if BYTES.match?(word)
      unless value&.between?(minimum, MAX_DECLARED_BYTES)
        field_error(field, "#{word} is not a byte count from #{minimum} to #{MAX_DECLARED_BYTES}")
      end
      value
    end

    def field_error(field, message)
      raise StackProofError, "stack proof: #{Terminal.escape(field.path)}:#{field.line}: #{Terminal.escape(message)}"
    end

    private_class_method :fields, :single, :allowances, :tick_entries, :leaves, :identifier, :byte_count,
                         :field_error
  end
end
