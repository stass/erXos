# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'origin'

module Erx
  module LicenseExpression
    # LicenseRef-DJB-public-domain is the statement "D. J. Bernstein / Public domain." in
    # ChaCha20's own files. It states no conditions; listing it here is the judgement that
    # such a statement permits what the licenses beside it do.
    PERMISSIVE = %w[BSD-2-Clause BSD-3-Clause MIT ISC 0BSD Apache-2.0 Zlib
                    BSL-1.0 Unicode-3.0 Unicode-DFS-2016 LicenseRef-DJB-public-domain].freeze
    # Licenses that cover font data only. A caller that states its input's OFL-1.1 content is
    # font data (font_data: true) has them admitted for that input alone, as grants that are
    # not permissive; every other input, and every other license, is judged by PERMISSIVE and
    # allow_restricted alone. Code
    # under OFL-1.1 is not font data, and its input does not state it is.
    FONT_DATA_ONLY = %w[OFL-1.1].freeze
    PRECEDENCE = { 'OR' => 1, 'AND' => 2 }.freeze
    module_function

    # SPDX grouping is bounded by Attribution's grammar. Postfix evaluation
    # avoids input-controlled recursion, including long unparenthesized chains.
    # AND needs both grants; OR selects one, preferring a permissive grant. font_data: true says
    # the expression's FONT_DATA_ONLY licenses cover font data in the input being judged.
    def select(expression, allow_restricted:, font_data: false)
      Attribution.validate_expression(expression)
      raise Error, 'font_data is true or false' unless [true, false].include?(font_data)
      stack = []
      postfix(expression).each do |item|
        if item.is_a?(String)
          permissive = PERMISSIVE.include?(item) || item == 'Apache-2.0 WITH LLVM-exception'
          admitted = permissive || allow_restricted || (font_data && FONT_DATA_ONLY.include?(item))
          stack << { 'license' => item.freeze, 'grants' => [item].freeze,
                     'permissive' => permissive, 'allowed' => admitted }.freeze
        else
          right = stack.pop
          left = stack.pop
          raise Error, 'incomplete license expression' unless left && right
          if item == :and
            stack << { 'license' => "(#{left.fetch('license')} AND #{right.fetch('license')})".freeze,
                       'grants' => (left.fetch('grants') + right.fetch('grants')).uniq.freeze,
                       'permissive' => left.fetch('permissive') && right.fetch('permissive'),
                       'allowed' => left.fetch('allowed') && right.fetch('allowed') }.freeze
          else
            selected = if right.fetch('permissive') && !left.fetch('permissive')
                         right
                       elsif left.fetch('allowed')
                         left
                       else
                         right
                       end
            stack << selected
          end
        end
      end
      unless stack.size == 1 && stack.first.fetch('allowed')
        raise Error, 'license expression has no permitted grant'
      end
      stack.first
    end

    def postfix(expression)
      output = []
      operators = []
      exception = false
      expression.scan(/[A-Za-z0-9][A-Za-z0-9.+_:\-]*|[()]/).each do |token|
        case token
        when '('
          operators << token
        when ')'
          output << operator(operators.pop) until operators.last == '('
          operators.pop
        when 'AND', 'OR'
          while operators.last && operators.last != '(' && PRECEDENCE.fetch(operators.last) >= PRECEDENCE.fetch(token)
            output << operator(operators.pop)
          end
          operators << token
        when 'WITH'
          exception = true
        else
          if exception
            output[-1] = output.last + ' WITH ' + token
            exception = false
          else
            output << token
          end
        end
      end
      output << operator(operators.pop) until operators.empty?
      output.freeze
    end
    private_class_method :postfix

    def operator(value)
      value == 'AND' ? :and : :or
    end
    private_class_method :operator
  end
end
