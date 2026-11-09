# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # A field of a tuple, a map or a union's case: its name and its type's.
    WebField = Struct.new(:name, :type, keyword_init: true)
    # A union's member. RECURSIVE is true when a field reaches the union
    # again, which only a union with a depth allows.
    WebCase = Struct.new(:name, :tag, :fields, :recursive, keyword_init: true)
    # One type of web.txt. FORM is integer, boolean, bytes, text, digits,
    # stopgap, ui_record, list, tuple, map or union. BITS, MINIMUM and MAXIMUM
    # bound an integer; MAXIMUM is also the byte bound of the sized forms and
    # a list's count bound, and EXACT makes a bytes type's length exactly
    # MAXIMUM. ELEMENT names a list's element type, FIELDS a tuple's or map's
    # fields, CASES a union's members in tag order. DEPTH is a union's level
    # count or nil, MESSAGE the byte bound of a union that is a whole message
    # or nil.
    WebType = Struct.new(:name, :form, :bits, :minimum, :maximum, :exact, :element, :fields, :cases,
                         :depth, :message, keyword_init: true) do
      def references
        case form
        when 'list' then [element]
        when 'tuple', 'map' then fields.map(&:type)
        when 'union' then cases.flat_map { |entry| entry.fields.map(&:type) }
        else []
        end
      end
    end
    # TYPES maps each name to its type, in declaration order; MESSAGES names
    # the message unions; STOPGAPS are the inspection schema's stopgap
    # reporters, the names a stopgap type admits.
    # LIMITS are the root limits named web_*, the protocol's bounds.
    WebSchema = Struct.new(:version, :types, :messages, :stopgaps, :limits, keyword_init: true)

    # The reader of the one `web VERSION` declaration of abi/protocols/web.txt
    # (docs/design-abi.md, "Web protocol"). It refuses every source the
    # grammar refuses and returns a frozen schema whose references all
    # resolve and whose type graph is acyclic but for a depth union's cases.
    module Web
      NAME = /\A[a-z][a-z0-9]*(_[a-z0-9]+)*\z/.freeze
      NAME_MAX = 63
      U32_MAX = 0xffff_ffff
      BITS = { 'u8' => 8, 'u16' => 16, 'u32' => 32 }.freeze
      DEPTH_MAX = 8
      # A stopgap reporter's longest name, the ui.txt status block's bound.
      STOPGAP_MAX = 63
      # Erlang's built-in type names and boolean, which the codecs read
      # without a declaration: no type may take one.
      RESERVED = %w[any arity atom binary bitstring boolean byte char dynamic float fun function identifier integer
                    iodata iolist list map maybe_improper_list mfa module neg_integer nil no_return node
                    non_neg_integer none nonempty_binary nonempty_bitstring nonempty_improper_list nonempty_list
                    nonempty_maybe_improper_list nonempty_string number pid port pos_integer reference string
                    term timeout tuple].freeze

      module_function

      def validate(declarations, limits:, stopgaps:)
        return nil if declarations.empty?

        declarations.drop(1).each { |extra| extra.fail!('web.txt declares one web version') }
        declaration = declarations.first
        version = declaration.args
        declaration.fail!('web takes version 1') unless version == ['1']
        stopgaps.each { |name| declaration.fail!("stopgap #{name} exceeds #{STOPGAP_MAX} bytes") if name.bytesize > STOPGAP_MAX }
        types = {}
        groups(declaration.members).each do |line, cases|
          type = read_type(line, cases, limits)
          line.fail!("type #{type.name} is declared twice") if types.key?(type.name)
          types[type.name] = type
        end
        resolve(types, declaration)
        schema = WebSchema.new(version: 1, types: mark_recursion(types, declaration),
                               messages: types.values.select(&:message).map(&:name), stopgaps: stopgaps.dup,
                               limits: limits.select { |name, _| name.start_with?('web_') }.sort.to_h)
        declaration.fail!('web.txt declares no message union') if schema.messages.empty?
        Model.freeze_value(schema)
      end

      # Each type line and the case lines beneath it.
      def groups(lines)
        lines.each_with_object([]) do |line, result|
          if line.indent == 2
            result << [line, []]
          else
            result.last.last << line
          end
        end
      end

      def read_type(line, cases, limits)
        form, name, *rest = line.words
        line.fail!("web type name #{name.inspect} is not a lower_snake name of at most #{NAME_MAX} bytes") unless name?(name)
        line.fail!("#{name} is reserved") if RESERVED.include?(name)
        unless form == 'union' || cases.empty?
          line.fail!("#{form} #{name} takes no members")
        end
        case [form, rest]
        in ['integer', [width]] then integer(line, name, width, nil)
        in ['integer', [width, 'min', minimum]] then integer(line, name, width, Syntax.integer(minimum, line: line))
        in ['bytes', [max]] then WebType.new(name: name, form: form, maximum: bound(line, max, limits), exact: false)
        in ['bytes', [max, 'exact']] then WebType.new(name: name, form: form, maximum: bound(line, max, limits), exact: true)
        in ['text' | 'digits' | 'ui_record', [max]]
          WebType.new(name: name, form: form, maximum: bound(line, max, limits), exact: false)
        in ['stopgap', []] then WebType.new(name: name, form: form, maximum: STOPGAP_MAX, exact: false)
        in ['list', [element, max]] then WebType.new(name: name, form: form, element: element, maximum: bound(line, max, limits))
        in ['tuple' | 'map', [_, *]] then WebType.new(name: name, form: form, fields: fields(line, rest))
        in ['union', options] then union(line, cases, name, options, limits)
        else line.fail!("unknown web type form or arguments: #{line.words.join(' ')}")
        end
      end

      def integer(line, name, width, minimum)
        bits = BITS.fetch(width) { line.fail!("integer width #{width} is not u8, u16 or u32") }
        maximum = (1 << bits) - 1
        minimum ||= 0
        line.fail!("integer #{name}'s minimum #{minimum} is outside its width") unless (0..maximum).cover?(minimum)
        WebType.new(name: name, form: 'integer', bits: bits, minimum: minimum, maximum: maximum)
      end

      # A limit's name or a number, from 1 to the largest u32.
      def bound(line, token, limits)
        value = token.match?(/\A(0x)?[0-9a-f]+\z/) ? Syntax.integer(token, line: line) : web_limit(limits, token)
        line.fail!("#{token} is neither a number nor a web_* limit") unless value
        line.fail!("bound #{token} is not between 1 and #{U32_MAX}") unless (1..U32_MAX).cover?(value)
        value
      end

      def fields(line, tokens)
        tokens.map do |token|
          name, type = token.split(':', 2)
          line.fail!("field #{token.inspect} is not NAME:TYPE") unless name?(name) && type
          WebField.new(name: name, type: type)
        end.tap do |list|
          duplicate = list.map(&:name).tally.find { |_, count| count > 1 }
          line.fail!("field #{duplicate.first} is declared twice") if duplicate
        end
      end

      def union(line, case_lines, name, options, limits)
        depth = nil
        message = nil
        until options.empty?
          case options
          in ['depth', value, *rest] then depth = bound(line, value, limits)
          in ['message', value, *rest] then message = bound(line, value, limits)
          else line.fail!("unknown union option #{options.first}")
          end
          options = rest
        end
        line.fail!("union #{name}'s depth exceeds #{DEPTH_MAX}") if depth && depth > DEPTH_MAX
        line.fail!("message union #{name} takes no depth") if depth && message
        cases = case_lines.map { |entry| union_case(entry) }
        line.fail!("union #{name} has no case") if cases.empty?
        %i[name tag].each do |key|
          duplicate = cases.map(&key).tally.find { |_, count| count > 1 }
          line.fail!("union #{name} repeats case #{key} #{duplicate.first}") if duplicate
        end
        WebType.new(name: name, form: 'union', cases: cases.sort_by(&:tag), depth: depth, message: message)
      end

      def union_case(line)
        keyword, name, tag, *rest = line.words
        line.fail!("expected case NAME TAG FIELD:TYPE..., not #{keyword}") unless keyword == 'case' && name?(name) && tag
        number = Syntax.integer(tag, line: line)
        line.fail!("case #{name}'s tag #{number} is not from 1 to 255") unless (1..255).cover?(number)
        fields = fields(line, rest)
        line.fail!("case #{name} names a field tag, the TypeScript discriminant") if fields.any? { |field| field.name == 'tag' }
        WebCase.new(name: name, tag: number, fields: fields, recursive: false)
      end

      # Every reference names a declared type or boolean, and nothing names a
      # message union, which is only ever a whole message.
      def resolve(types, declaration)
        types.each_value do |type|
          type.references.each do |reference|
            next if reference == 'boolean'

            target = types[reference] || declaration.fail!("#{type.name} names undeclared type #{reference}")
            declaration.fail!("#{type.name} names message union #{reference}") if target.message
          end
        end
        depth_unions = types.values.select(&:depth)
        declaration.fail!('web.txt declares at most one union with a depth') if depth_unions.size > 1
      end

      # Without the edges out of a depth union's cases the type graph must be
      # acyclic; with them, a case is recursive when it reaches its union.
      def mark_recursion(types, declaration)
        edges = types.transform_values { |type| type.depth ? [] : type.references - ['boolean'] }
        acyclic!(edges, declaration)
        types.transform_values do |type|
          next type unless type.depth

          cases = type.cases.map do |entry|
            recursive = entry.fields.any? { |field| reaches?(types, field.type, type.name) }
            WebCase.new(name: entry.name, tag: entry.tag, fields: entry.fields, recursive: recursive)
          end
          declaration.fail!("depth union #{type.name} has no case that ends its nesting") if cases.all?(&:recursive)
          WebType.new(**type.to_h.merge(cases: cases))
        end
      end

      def acyclic!(edges, declaration)
        state = {}
        visit = lambda do |name, trail|
          return if state[name] == :done
          declaration.fail!("type cycle #{(trail + [name]).join(' -> ')} passes no depth union") if state[name] == :open

          state[name] = :open
          edges.fetch(name).each { |next_name| visit.call(next_name, trail + [name]) }
          state[name] = :done
        end
        edges.each_key { |name| visit.call(name, []) }
      end

      def reaches?(types, from, goal, seen = {})
        return true if from == goal
        return false if from == 'boolean' || seen[from]

        seen[from] = true
        types.fetch(from).references.any? { |next_name| reaches?(types, next_name, goal, seen) }
      end

      # Only the web_* limits, the ones web.txt and ui.txt declare and the hash covers.
      def web_limit(limits, name) = name.start_with?('web_') ? limits[name] : nil

      def name?(name) = name.is_a?(String) && name.bytesize <= NAME_MAX && name.match?(NAME)
    end
  end
end
