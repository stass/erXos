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
    SINGLETONS = %w[terminal unicode unsafe_categories unsafe_property exceptions invalid_scalars kernel_ascii grammar renderer_operations renderer_styles].freeze
    OUTPUTS = %w[include/erx/terminal_ascii.h erlang/apps/erx/src/erx_text_tables.erl
                 tools/generated/terminal_tables.rb tools/generated/terminal_notices.json
                 abi/terminal_generated.json].freeze
    module_function

    def source(bytes)
      text = bounded_text(bytes, maximum: 65_536, ascii: true)
      model = { 'pass' => {}, 'token' => {}, 'parameter' => {}, 'sgr' => {},
                'literal' => {}, 'sequence' => {}, 'reset' => {}, 'input' => {} }
      text.each_line.with_index(1) do |line, number|
        words = line.split('#', 2).first.to_s.split
        next if words.empty?
        kind, *values = words
        if SINGLETONS.include?(kind)
          raise Error, "duplicate terminal declaration at #{number}" if model.key?(kind)
          model[kind] = singleton(kind, values)
        elsif %w[pass token parameter sgr literal sequence reset input].include?(kind)
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
      when 'unsafe_property'
        raise Error, 'unsupported Unicode property' unless values == ['Default_Ignorable_Code_Point']
        values.first
      when 'renderer_operations', 'renderer_styles'
        raise Error, 'duplicate renderer name' unless !values.empty? && values.uniq == values
        values.each { |value| identifier(value) }
        values
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
      when 'grammar'
        fields = assignments(values, %w[sequence_bytes parameters digits separator intermediates])
        { 'sequence_bytes' => decimal(fields.fetch('sequence_bytes'), maximum: 256),
          'parameters' => decimal(fields.fetch('parameters'), maximum: 64),
          'digits' => decimal(fields.fetch('digits'), maximum: 8),
          'separator' => hex_bytes(fields.fetch('separator'), minimum: 1, maximum: 1).first,
          'intermediates' => interval(fields.fetch('intermediates'), maximum: 255) }
      end
    end
    private_class_method :singleton

    def declaration(kind, values)
      case kind
      when 'input'
        name, path = values
        unless values.size == 2 && %w[unicode_data properties prim_tty io_ansi].include?(name) &&
               path.start_with?('otp/') && path.split('/').all? { |part| part.match?(/\A[A-Za-z0-9_.-]+\z/) && !%w[. ..].include?(part) }
          raise Error, 'invalid terminal input path'
        end
        [name, path]
      when 'pass'
        name, *characters = values
        raise Error, 'unknown text escape profile' unless %w[strict line].include?(name)
        [name, characters.empty? ? [] : points(characters)]
      when 'token'
        name, prefix, first, last, suffix = values
        unless values.size == 5 && %w[codepoint byte kernel].include?(name) &&
               [prefix, suffix].all? { |part| part.match?(/\A[!-~]{1,8}\z/) }
          raise Error, 'invalid escape token grammar'
        end
        minimum = decimal(first, maximum: 6)
        maximum = decimal(last, maximum: 6)
        raise Error, 'invalid escape token width' unless minimum.positive? && minimum <= maximum
        [name, { 'prefix' => prefix, 'minimum' => minimum, 'maximum' => maximum,
                 'suffix' => suffix == '-' ? '' : suffix, 'digits' => 'uppercase_hex' }]
      when 'parameter'
        name, first, last, bounds, defaults = values
        raise Error, 'invalid parameter declaration' unless values.size == 5
        identifier(name)
        minimum = decimal(first, maximum: 64)
        maximum = decimal(last, maximum: 64)
        raise Error, 'invalid parameter count' unless minimum <= maximum
        limits = parameter_values(bounds)
        default = defaults == '-' ? [] : defaults.split(',').map do |value|
          %w[rows columns].include?(value) ? value : decimal(value, maximum: 99_999)
        end
        [name, { 'minimum_count' => minimum, 'maximum_count' => maximum,
                 'bounds' => limits, 'defaults' => default, 'zero_is_default' => limits.any? { |value| %w[rows columns].include?(value) } }]
      when 'sgr'
        name, *fields = values
        if %w[simple forbidden].include?(name)
          selectors = fields.flat_map { |field| interval(field, base: 10, maximum: 255).then { |first, last| (first..last).to_a } }
          raise Error, 'duplicate SGR selector' if selectors.empty? || selectors.uniq != selectors
          [name, selectors]
        elsif %w[indexed rgb].include?(name)
          parts = assignments(fields, %w[selectors mode operands maximum])
          [name, { 'selectors' => parts.fetch('selectors').split(',').map { |value| decimal(value, maximum: 255) },
                   'mode' => decimal(parts.fetch('mode'), maximum: 255),
                   'operands' => decimal(parts.fetch('operands'), maximum: 3),
                   'maximum' => decimal(parts.fetch('maximum'), maximum: 255) }]
        else
          raise Error, 'unknown SGR grammar'
        end
      when 'literal', 'sequence'
        profile, name, *fields = values
        raise Error, 'unknown terminal allowlist profile' unless %w[prim_tty terminal_mode].include?(profile)
        identifier(name)
        if kind == 'literal'
          raise Error, 'invalid literal sequence' unless fields.size == 1
          value = { 'profile' => profile, 'name' => name, 'bytes' => hex_bytes(fields.first, minimum: 1, maximum: 64) }
        else
          raise Error, 'invalid control sequence declaration' unless fields.size == 5
          introducer, private_bytes, intermediate, final, parameters = fields
          intro = hex_bytes(introducer, minimum: 2, maximum: 2)
          raise Error, 'unsupported control introducer' unless intro == [27, 91]
          private_prefix = private_bytes == '-' ? [] : hex_bytes(private_bytes, minimum: 1, maximum: 1)
          raise Error, 'invalid CSI private prefix' unless private_prefix.all? { |byte| byte.between?(0x3c, 0x3f) }
          middle = intermediate == '-' ? [] : hex_bytes(intermediate, minimum: 1, maximum: 4)
          raise Error, 'invalid CSI intermediate' unless middle.all? { |byte| byte.between?(0x20, 0x2f) }
          final_byte = hex_bytes(final, minimum: 1, maximum: 1).first
          raise Error, 'invalid CSI final' unless final_byte.between?(0x40, 0x7e)
          value = { 'profile' => profile, 'name' => name, 'introducer' => intro,
                    'private' => private_prefix, 'intermediate' => middle,
                    'final' => final_byte, 'parameters' => identifier(parameters) }
        end
        ["#{profile}/#{name}", value]
      when 'reset'
        name, reference, parameters = values
        raise Error, 'invalid terminal reset' unless values.size == 3
        arguments = parameters == '-' ? [] : parameters.split(',').map { |value| decimal(value, maximum: 99_999) }
        [identifier(name), { 'sequence' => identifier(reference), 'parameters' => arguments }]
      end
    end
    private_class_method :declaration

    def validate_model(model)
      raise Error, 'incomplete terminal rules' unless (SINGLETONS - model.keys).empty?
      raise Error, 'incomplete terminal input list' unless model.fetch('input').keys.sort == %w[io_ansi prim_tty properties unicode_data]
      raise Error, 'incomplete text escape profiles' unless model.fetch('pass').keys.sort == %w[line strict]
      raise Error, 'incomplete escape token grammar' unless model.fetch('token').keys.sort == %w[byte codepoint kernel]
      raise Error, 'incomplete SGR grammar' unless model.fetch('sgr').keys.sort == %w[forbidden indexed rgb simple]
      unless (model.fetch('sgr').fetch('simple') & model.fetch('sgr').fetch('forbidden')).empty?
        raise Error, 'forbidden SGR selector in simple rendition allowlist'
      end
      selector_modes = []
      %w[indexed rgb].each do |kind|
        form = model.fetch('sgr').fetch(kind)
        selectors = form.fetch('selectors')
        denied = model.fetch('sgr').fetch('simple') + model.fetch('sgr').fetch('forbidden')
        unless !selectors.empty? && selectors.uniq == selectors && (selectors & denied).empty? &&
               form.fetch('operands').positive?
          raise Error, 'overlapping or empty compound SGR selectors'
        end
        selector_modes.concat(selectors.map { |selector| [selector, form.fetch('mode')] })
      end
      raise Error, 'ambiguous compound SGR form' unless selector_modes.uniq == selector_modes
      grammar = model.fetch('grammar')
      raise Error, 'empty sequence grammar bound' unless %w[sequence_bytes parameters digits].all? { |key| grammar.fetch(key).positive? }
      model.fetch('parameter').each_value do |rule|
        raise Error, 'parameter count exceeds grammar' if rule.fetch('maximum_count') > grammar.fetch('parameters')
        expected = rule.fetch('bounds') == ['sgr'] ? 1 : rule.fetch('maximum_count')
        unless rule.fetch('bounds').size == expected && rule.fetch('defaults').size == expected
          raise Error, 'parameter bounds/defaults do not match count'
        end
      end
      model.fetch('sequence').each_value do |sequence|
        raise Error, 'unknown sequence parameter rule' unless model.fetch('parameter').key?(sequence.fetch('parameters'))
      end
      %w[prim_tty terminal_mode].each do |profile|
        rows = model.fetch('sequence').values.select { |row| row.fetch('profile') == profile }
        keys = rows.map { |row| [row.fetch('introducer'), row.fetch('private'), row.fetch('intermediate'), row.fetch('final'), row.fetch('parameters')] }
        raise Error, 'duplicate terminal sequence pattern' unless keys.uniq == keys
        raise Error, 'terminal profile has no sequences' if rows.empty?
      end
      model.fetch('literal').each_value do |literal|
        raise Error, 'literal exceeds sequence grammar' if literal.fetch('bytes').size > grammar.fetch('sequence_bytes')
      end
      model.fetch('reset').each_value do |reset|
        key = 'terminal_mode/' + reset.fetch('sequence')
        literal = model.fetch('literal')[key]
        sequence = model.fetch('sequence')[key]
        raise Error, 'reset references an unknown terminal-mode sequence' unless literal || sequence
        if literal
          raise Error, 'literal reset has parameters' unless reset.fetch('parameters').empty?
        else
          rule = model.fetch('parameter').fetch(sequence.fetch('parameters'))
          unless reset_parameters_valid?(reset.fetch('parameters'), rule, model.fetch('sgr'))
            raise Error, 'reset operands differ from terminal allowlist'
          end
        end
      end
    end
    private_class_method :validate_model

    # Source resets are complete, size-independent constructors, not streamed
    # terminal input. Runtime-size operands use omitted parameters instead.
    def reset_parameters_valid?(values, rule, sgr)
      return false unless values.size.between?(rule.fetch('minimum_count'), rule.fetch('maximum_count'))
      return sgr_parameters_valid?(values, sgr) if rule.fetch('bounds') == ['sgr']
      values.each_with_index.all? do |value, index|
        bound = rule.fetch('bounds')[index]
        bound.is_a?(Array) && value.between?(*bound)
      end
    end
    private_class_method :reset_parameters_valid?

    def sgr_parameters_valid?(values, sgr)
      cursor = 0
      while cursor < values.size
        selector = values[cursor]
        if sgr.fetch('simple').include?(selector)
          cursor += 1
          next
        end
        form = %w[indexed rgb].map { |name| sgr.fetch(name) }.find do |candidate|
          candidate.fetch('selectors').include?(selector) && values[cursor + 1] == candidate.fetch('mode')
        end
        return false unless form
        count = form.fetch('operands')
        return false if cursor + 2 + count > values.size
        return false unless values.slice(cursor + 2, count).all? { |value| value.between?(0, form.fetch('maximum')) }
        cursor += 2 + count
      end
      true
    end
    private_class_method :sgr_parameters_valid?

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

    def assignments(values, names)
      fields = values.to_h do |value|
        key, separator, member = value.partition('=')
        raise Error, 'invalid terminal assignment' if separator.empty? || member.empty?
        [key, member]
      end
      raise Error, 'unknown or duplicate terminal assignment' unless fields.size == values.size && fields.keys.sort == names.sort
      fields
    end
    private_class_method :assignments

    def parameter_values(value)
      return [] if value == '-'
      value.split(',').map do |member|
        if %w[rows columns sgr].include?(member)
          member
        else
          interval(member, base: 10, maximum: 99_999)
        end
      end
    end
    private_class_method :parameter_values

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

    def interval(value, base: 16, maximum: UNICODE_MAX)
      parts = value.split('..', -1)
      pattern = base == 16 ? /\A[0-9A-F]{1,6}\z/ : /\A[0-9]{1,5}\z/
      raise Error, 'invalid terminal interval' unless parts.size.between?(1, 2) && parts.all? { |part| part.match?(pattern) }
      first, last = parts.map { |part| Integer(part, base) }
      last ||= first
      raise Error, 'terminal interval outside bound' unless first <= last && last <= maximum
      [first, last]
    end
    private_class_method :interval

    def decimal(value, maximum:)
      raise Error, 'invalid terminal integer' unless value.is_a?(String) && value.match?(/\A\d{1,5}\z/)
      result = Integer(value, 10)
      raise Error, 'terminal integer exceeds bound' if result > maximum
      result
    end
    private_class_method :decimal

    def identifier(value)
      raise Error, 'invalid terminal identifier' unless value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
      value
    end
    private_class_method :identifier

    def hex_bytes(value, minimum:, maximum:)
      unless value.is_a?(String) && value.match?(/\A(?:[0-9A-F]{2})+\z/) && value.bytesize.between?(minimum * 2, maximum * 2)
        raise Error, 'invalid terminal byte spelling'
      end
      [value].pack('H*').bytes
    end
    private_class_method :hex_bytes

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
