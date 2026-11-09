# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'origin'

module Erx
  module TerminalRules
    UNICODE_MAX = 0x10ffff
    CATEGORIES = %w[Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So Zs Zl Zp Cc Cf Cs Co Cn].freeze
    # The escape tokens: the line escape's code point and byte, the kernel log's
    # byte, and the /proc field escape's byte.
    TOKENS = %w[byte codepoint field kernel].freeze
    SINGLETONS = %w[terminal unicode unsafe_categories unsafe_property exceptions invalid_scalars kernel_ascii
                    width_zero_categories width_zero_exceptions width_wide].freeze
    EAST_ASIAN_WIDTHS = %w[A F H N Na W].freeze
    INPUTS = %w[east_asian_width properties unicode_data].freeze
    OUTPUTS = %w[include/erx/terminal_ascii.h erlang/apps/erx/src/erx_text_tables.erl
                 tools/generated/terminal_tables.rb tools/generated/terminal_notices.json
                 web/src/generated/terminal_tables.ts erlang/apps/erx_display/src/erx_vt_width.erl
                 include/erx/vt_width.h].freeze
    # The licence of the Unicode inputs, which every generated table declares.
    LICENSE = 'Unicode-3.0'
    module_function

    def source(bytes)
      text = bounded_text(bytes, maximum: 65_536, ascii: true)
      model = { 'token' => {}, 'input' => {} }
      text.each_line.with_index(1) do |line, number|
        words = line.split('#', 2).first.to_s.split
        next if words.empty?
        kind, *values = words
        if SINGLETONS.include?(kind)
          raise Error, "duplicate terminal declaration at #{number}" if model.key?(kind)
          model[kind] = singleton(kind, values)
        elsif %w[token input].include?(kind)
          key, value = declaration(kind, values)
          raise Error, "duplicate terminal #{kind} at #{number}" if model.fetch(kind).key?(key)
          model.fetch(kind)[key] = value
        else
          raise Error, "unknown terminal declaration at #{number}"
        end
      end
      validate_model(model)
      immutable(model)
    end

    def singleton(kind, values)
      case kind
      when 'terminal'
        raise Error, 'unsupported terminal rules version' unless values == ['1']
        1
      when 'unicode'
        raise Error, 'invalid Unicode version' unless values.size == 1 && values.first.match?(/\A\d+\.\d+\.\d+\z/)
        values.first
      when 'unsafe_categories'
        raise Error, 'invalid Unicode categories' unless !values.empty? && values.uniq == values && (values - CATEGORIES).empty?
        values
      when 'width_zero_categories'
        raise Error, 'invalid zero-width categories' unless !values.empty? && values.uniq == values && (values - CATEGORIES).empty?
        values
      when 'width_zero_exceptions'
        points(values)
      when 'width_wide'
        raise Error, 'invalid wide East Asian Width values' unless !values.empty? && values.uniq == values && (values - EAST_ASIAN_WIDTHS).empty?
        values
      when 'unsafe_property'
        raise Error, 'unsupported Unicode property' unless values == ['Default_Ignorable_Code_Point']
        values.first
      when 'exceptions'
        points(values)
      when 'invalid_scalars'
        raise Error, 'invalid scalar interval' unless values.size == 2
        interval(values.join('..'))
      when 'kernel_ascii'
        raise Error, 'invalid kernel ASCII rule' unless values.size == 2
        first, last = points(values)
        raise Error, 'kernel rule exceeds printable ASCII' unless first >= 0x20 && first <= last && last <= 0x7e
        { 'range' => [first, last] }
      end
    end
    private_class_method :singleton

    def declaration(kind, values)
      case kind
      when 'input'
        name, path = values
        unless values.size == 2 && INPUTS.include?(name) &&
               path.start_with?('otp/') && path.split('/').all? { |part| part.match?(/\A[A-Za-z0-9_.-]+\z/) && !%w[. ..].include?(part) }
          raise Error, 'invalid terminal input path'
        end
        [name, path]
      when 'token'
        name, prefix, first, last, suffix = values
        unless values.size == 5 && TOKENS.include?(name) &&
               [prefix, suffix].all? { |part| part.match?(/\A[!-~]{1,8}\z/) }
          raise Error, 'invalid escape token grammar'
        end
        minimum = decimal(first, maximum: 6)
        maximum = decimal(last, maximum: 6)
        raise Error, 'invalid escape token width' unless minimum.positive? && minimum <= maximum
        # A byte token writes one byte in exactly two digits; a code point token
        # must have room for U+10FFFF.
        raise Error, 'invalid byte token width' if name != 'codepoint' && [minimum, maximum] != [2, 2]
        raise Error, 'invalid code point token width' if name == 'codepoint' && maximum < 6
        # The field escape is injective only if every token it writes starts
        # with the backslash it doubles and differs from its \t, \n and \\.
        if name == 'field' && !(prefix.match?(/\A\\[!-~]\z/) && !['\\', 't', 'n'].include?(prefix[1]) && suffix == '-')
          raise Error, 'the field token must be a backslash and one character other than t, n or a backslash'
        end
        [name, { 'prefix' => prefix, 'minimum' => minimum, 'maximum' => maximum,
                 'suffix' => suffix == '-' ? '' : suffix, 'digits' => 'uppercase_hex' }]
      end
    end
    private_class_method :declaration

    def validate_model(model)
      raise Error, 'incomplete terminal rules' unless (SINGLETONS - model.keys).empty?
      raise Error, 'incomplete terminal input list' unless model.fetch('input').keys.sort == INPUTS
      raise Error, 'incomplete escape token grammar' unless model.fetch('token').keys.sort == TOKENS
    end
    private_class_method :validate_model

    def unicode_data(bytes)
      text = bounded_text(bytes, maximum: 8 * 1024 * 1024)
      records = []
      pending = nil
      previous = -1
      text.each_line do |line|
        fields = line.chomp.split(';', -1)
        raise Error, 'invalid UnicodeData record' unless fields.size == 15
        point = point(fields.first)
        name, category = fields[1], fields[2]
        raise Error, 'unordered UnicodeData or unknown category' unless point > previous && CATEGORIES.include?(category)
        previous = point
        if name.end_with?(', First>')
          raise Error, 'nested UnicodeData range' if pending
          pending = [point, name.delete_suffix(', First>'), category]
        elsif name.end_with?(', Last>')
          unless pending && pending[1] == name.delete_suffix(', Last>') && pending[2] == category
            raise Error, 'unmatched UnicodeData range'
          end
          records << [pending.first, point, category]
          pending = nil
        else
          raise Error, 'unterminated UnicodeData range' if pending
          records << [point, point, category]
        end
      end
      raise Error, 'empty or incomplete UnicodeData' if records.empty? || pending
      immutable(records)
    end

    def derived_properties(bytes, version:)
      text = bounded_text(bytes, maximum: 8 * 1024 * 1024)
      raise Error, 'Unicode property version differs from declaration' unless text.lines.first == "# DerivedCoreProperties-#{version}.txt\n"
      selected = []
      previous = {}
      text.each_line do |line|
        content = line.split('#', 2).first.to_s.strip
        next if content.empty?
        fields = content.split(';').map(&:strip)
        unless fields.size.between?(2, 3) && fields.drop(1).all? { |field| field.match?(/\A[A-Za-z][A-Za-z_]*\z/) }
          raise Error, 'invalid DerivedCoreProperties record'
        end
        first, last = interval(fields.first)
        key = fields.drop(1)
        raise Error, 'overlapping Unicode property ranges' if previous.key?(key) && first <= previous.fetch(key)
        previous[key] = last
        if fields[1] == 'Default_Ignorable_Code_Point'
          raise Error, 'unexpected default-ignorable property value' unless fields.size == 2
          selected << [first, last]
        end
      end
      raise Error, 'missing default-ignorable property' if selected.empty?
      immutable(selected)
    end

    # EastAsianWidth.txt's ranges, [first, last, value], in order and disjoint.
    # A code point it does not list is N, the file's one @missing default.
    def east_asian_widths(bytes, version:)
      text = bounded_text(bytes, maximum: 8 * 1024 * 1024)
      raise Error, 'East Asian Width version differs from declaration' unless text.lines.first == "# EastAsianWidth-#{version}.txt\n"
      records = []
      text.each_line do |line|
        if line.start_with?('# @missing:') && line.strip != '# @missing: 0000..10FFFF; N'
          raise Error, 'EastAsianWidth has a default other than N'
        end
        content = line.split('#', 2).first.to_s.strip
        next if content.empty?
        fields = content.split(';').map(&:strip)
        raise Error, 'invalid EastAsianWidth record' unless fields.size == 2 && EAST_ASIAN_WIDTHS.include?(fields[1])
        first, last = interval(fields.first)
        raise Error, 'unordered or overlapping EastAsianWidth ranges' if !records.empty? && first <= records.last[1]
        records << [first, last, fields[1]]
      end
      raise Error, 'empty EastAsianWidth' if records.empty?
      immutable(records)
    end

    # The terminal's width of every code point whose width is not 1
    # (docs/design-display.md, "Cells and the grid state"), as sorted, disjoint
    # [first, last, width] ranges: 0 for the zero-width categories less their
    # exceptions, else 2 for the wide East Asian Width values.
    def width_intervals(model, records:, widths:)
      zero_categories = model.fetch('width_zero_categories')
      zero = merge(records.select { |_first, _last, category| zero_categories.include?(category) }
                          .map { |first, last, _category| [first, last] })
      zero = subtract(zero, model.fetch('width_zero_exceptions').sort.map { |point| [point, point] })
      wide_values = model.fetch('width_wide')
      wide = subtract(merge(widths.select { |_first, _last, value| wide_values.include?(value) }
                                  .map { |first, last, _value| [first, last] }), zero)
      ranges = (zero.map { |first, last| [first, last, 0] } + wide.map { |first, last| [first, last, 2] }).sort
      immutable(ranges)
    end

    def merge(intervals)
      intervals.sort.each_with_object([]) do |(first, last), result|
        if !result.empty? && first <= result.last[1] + 1
          result.last[1] = [result.last[1], last].max
        else
          result << [first, last]
        end
      end
    end
    private_class_method :merge

    # The parts of sorted, disjoint intervals outside sorted, disjoint holes.
    def subtract(intervals, holes)
      intervals.flat_map do |first, last|
        pieces = []
        start = first
        holes.each do |hole_first, hole_last|
          next if hole_last < start || hole_first > last
          pieces << [start, hole_first - 1] if hole_first > start
          start = hole_last + 1
        end
        pieces << [start, last] if start <= last
        pieces
      end
    end
    private_class_method :subtract

    def unsafe_intervals(model, records:, ignorables:)
      categories = model.fetch('unsafe_categories')
      selected = records.select { |_first, _last, category| categories.include?(category) }.map { |first, last, _category| [first, last] }
      if categories.include?('Cn')
        cursor = 0
        records.each do |first, last, _category|
          selected << [cursor, first - 1] if cursor < first
          cursor = last + 1
        end
        selected << [cursor, UNICODE_MAX] if cursor <= UNICODE_MAX
      end
      selected.concat(ignorables).push(model.fetch('invalid_scalars'))
      merged = selected.sort.each_with_object([]) do |(first, last), result|
        if !result.empty? && first <= result.last[1] + 1
          result.last[1] = [result.last[1], last].max
        else
          result << [first, last]
        end
      end
      model.fetch('exceptions').each do |exception|
        merged = merged.flat_map do |first, last|
          if exception.between?(first, last)
            [[first, exception - 1], [exception + 1, last]].select { |left, right| left <= right }
          else
            [[first, last]]
          end
        end
      end
      immutable(merged)
    end

    def bounded_text(bytes, maximum:, ascii: false)
      raise Error, 'terminal input exceeds byte bound' unless bytes.is_a?(String) && bytes.bytesize <= maximum
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && !text.include?("\0") && (!ascii || text.ascii_only?)
        raise Error, 'terminal input has invalid text encoding'
      end
      raise Error, 'terminal input line exceeds bound' if text.each_line.any? { |line| line.bytesize > 4096 }
      text
    end
    private_class_method :bounded_text

    def points(values)
      raise Error, 'empty or duplicate terminal points' if values.empty? || values.uniq != values
      values.map { |value| point(value) }
    end
    private_class_method :points

    def point(value)
      raise Error, 'invalid Unicode scalar number' unless value.is_a?(String) && value.match?(/\A[0-9A-F]{4,6}\z/)
      result = Integer(value, 16)
      raise Error, 'Unicode number exceeds codespace' if result > UNICODE_MAX
      result
    end
    private_class_method :point

    # A hexadecimal Unicode interval, "1F600" or "D800..DFFF".
    def interval(value)
      parts = value.split('..', -1)
      unless parts.size.between?(1, 2) && parts.all? { |part| part.match?(/\A[0-9A-F]{1,6}\z/) }
        raise Error, 'invalid terminal interval'
      end
      first, last = parts.map { |part| Integer(part, 16) }
      last ||= first
      raise Error, 'terminal interval outside bound' unless first <= last && last <= UNICODE_MAX
      [first, last]
    end
    private_class_method :interval

    def decimal(value, maximum:)
      raise Error, 'invalid terminal integer' unless value.is_a?(String) && value.match?(/\A\d\z/)
      result = Integer(value, 10)
      raise Error, 'terminal integer exceeds bound' if result > maximum
      result
    end
    private_class_method :decimal

    def immutable(value)
      case value
      when Hash then value.each { |key, member| immutable(key); immutable(member) }
      when Array then value.each { |member| immutable(member) }
      end
      value.freeze
    end
    private_class_method :immutable
  end
end
