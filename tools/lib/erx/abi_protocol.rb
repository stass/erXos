# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'

module Erx
  module ABI
    # A protocol declaration is a frame profile: the operations of a message
    # protocol carried as Erlang terms, each field bound to a kind whose bounds
    # the table states (abi/protocols/9p.txt documents the member syntax).
    # This pass closes every reference, so the emitter turns a valid model
    # into code without further checks; the result is frozen hashes, which
    # the Ruby emitter serializes like the rest of the schema.
    module Protocols
      BASE_KINDS = %w[u8 u16 u32 u64 alias].freeze
      INTEGER_BITS = { 'u8' => 8, 'u16' => 16, 'u32' => 32, 'u64' => 64 }.freeze
      REFUSALS = %w[nul slash empty dot dotdot].freeze
      MEASURES = %w[value bytes length packed].freeze
      RELATIONS = %w[le le_nonempty].freeze
      MAX_FIELDS = 32
      # The kind by which a request names a node: only a field of this kind can be
      # marked "directory".
      DIRECTORY_KIND = 'fid'
      MAX_ERRORS = 64
      # Names become Erlang atoms and functions: no reserved word, no dot, and no
      # kind whose check would clash with a BIF or a helper of the generated module.
      ERLANG_RESERVED = %w[after and andalso band begin bnot bor bsl bsr bxor case catch cond div else end
                           fun if let maybe not of or orelse receive rem try when xor].freeze
      RESERVED_KINDS = %w[atom binary bitstring boolean float function integer list list_of map number
                          pid port record reference tuple utf8].freeze

      module_function

      def validate(declarations, constants)
        names = {}
        declarations.map do |declaration|
          Model.arity(declaration.line, 2)
          name = atom_name(declaration.args[0], line: declaration.line)
          declaration.fail!('duplicate protocol') if names.key?(name)
          names[name] = true
          protocol(declaration, name, constants)
        end.freeze
      end

      def protocol(declaration, name, constants)
        errors = nil
        kinds = {}
        operations = []
        declaration.members.slice_before { |member| member.indent == 2 }.each do |line, *children|
          line.fail!('nested member has no parent') unless line.indent == 2
          keyword, *words = line.words
          case keyword
          when 'errors'
            line.fail!('duplicate errors list') if errors
            line.fail!('errors list must name 1 to 64 atoms') unless words.size.between?(1, MAX_ERRORS)
            errors = words.map { |word| atom_name(word, line: line) }
            line.fail!('duplicate error atom') unless errors.uniq.size == errors.size
          when 'integer', 'text', 'tuple', 'list', 'map'
            kind_name = atom_name(words.first, line: line)
            line.fail!("reserved kind name #{kind_name}") if RESERVED_KINDS.include?(kind_name)
            line.fail!("duplicate kind #{kind_name}") if kinds.key?(kind_name) || BASE_KINDS.include?(kind_name)
            line.fail!('only a map takes members') unless children.empty? || keyword == 'map'
            kinds[kind_name] = kind(keyword, words.drop(1), children, line, kinds, constants)
          when 'operation'
            operations << operation(line, words, children, kinds, constants)
          else
            line.fail!("unknown protocol member #{keyword}")
          end
        end
        declaration.fail!('protocol requires an errors list') unless errors
        declaration.fail!('protocol requires an operation') if operations.empty?
        Model.unique_values(operations.to_h { |item| [item.fetch(:name), item.fetch(:type)] },
                            label: 'operation type', line: declaration.line)
        unless operations.map { |item| item.fetch(:name) }.uniq.size == operations.size
          declaration.fail!('duplicate operation')
        end
        used = used_kinds(kinds, operations)
        unused = kinds.keys - used
        declaration.fail!("unused kinds #{unused.join(' ')}") unless unused.empty?
        { name: name, module: "#{name}_grammar", source: declaration.line.path,
          errors: errors.freeze, kinds: kinds.freeze,
          operations: operations.freeze }.freeze
      end

      def kind(form, words, children, line, kinds, constants)
        case form
        when 'integer' then integer_kind(words, line, constants)
        when 'text' then text_kind(words, line, constants)
        when 'tuple'
          line.fail!('a tuple has 1 to 32 elements') unless words.size.between?(1, MAX_FIELDS)
          { form: 'tuple', elements: words.map { |word| known_kind(word, line, kinds) }.freeze }.freeze
        when 'list' then list_kind(words, line, kinds, constants)
        when 'map'
          line.fail!('a map takes no options') unless words.empty?
          line.fail!('a map has 1 to 32 fields') unless children.size.between?(1, MAX_FIELDS)
          fields = children.map do |child|
            child.fail!('expected field NAME KIND') unless child.words.size == 3 && child.words.first == 'field'
            [atom_name(child.words[1], line: child), known_kind(child.words[2], child, kinds)]
          end
          line.fail!('duplicate map field') unless fields.map(&:first).uniq.size == fields.size
          { form: 'map', fields: fields.map(&:freeze).freeze }.freeze
        end
      end

      def integer_kind(words, line, constants)
        base, option, *values = words
        line.fail!('an integer is u8, u16, u32 or u64') unless INTEGER_BITS.key?(base)
        maximum = (1 << INTEGER_BITS.fetch(base)) - 1
        numbers = -> { values.map { |value| number(value, maximum, line, constants) } }
        result = { form: 'integer', base: base }
        case [option, values.size]
        in ['max', 1] then result[:max] = numbers.call.first
        in ['except', 1] then result[:except] = numbers.call.first
        in ['in', 1..16]
          result[:in] = numbers.call.freeze
          line.fail!('duplicate value') unless result[:in].map { |item| item.fetch(:value) }.uniq.size == values.size
        in ['or', 1] then result[:atom] = atom_name(values.first, line: line)
        else line.fail!('an integer takes max N, except N, in VALUES or or ATOM')
        end
        result.freeze
      end

      def text_kind(words, line, constants)
        line.fail!('a text starts with max N') unless words[0] == 'max' && words.size >= 2
        result = { form: 'text', max: number(words[1], 65_536, line, constants),
                   utf8: false, refuse: [] }
        rest = words.drop(2)
        if rest.first == 'utf8'
          result[:utf8] = true
          rest = rest.drop(1)
        end
        unless rest.empty?
          line.fail!('expected refuse followed by refusals') unless rest.first == 'refuse' && rest.size > 1
          refusals = rest.drop(1)
          line.fail!('unknown or duplicate refusal') unless refusals.all? { |item| REFUSALS.include?(item) } &&
                                                            refusals.uniq.size == refusals.size
          result[:refuse] = refusals
        end
        result[:refuse] = result[:refuse].freeze
        result.freeze
      end

      def list_kind(words, line, kinds, constants)
        element, max_word, maximum, *rest = words
        line.fail!('a list is ELEMENT max N [packed N]') unless max_word == 'max' && [0, 2].include?(rest.size)
        result = { form: 'list', element: known_kind(element, line, kinds),
                   max: number(maximum, 65_536, line, constants) }
        unless rest.empty?
          line.fail!('expected packed N') unless rest.first == 'packed'
          tuple = kinds[element]
          last = tuple && tuple[:form] == 'tuple' && kinds[tuple.fetch(:elements).last]
          line.fail!('a packed list holds tuples that end in a text') unless last && last[:form] == 'text'
          result[:packed] = number(rest[1], 65_536, line, constants)
        end
        result.freeze
      end

      def operation(line, words, children, kinds, constants)
        Model.arity(line, 3)
        name = atom_name(words[0], line: line)
        line.fail!('an operation cannot be named error') if name == 'error'
        type = number(words[1], 255, line, constants).fetch(:value)
        request = []
        reply = []
        checks = []
        directories = []
        marker = nil
        refused = false
        children.each do |child|
          keyword, *rest = child.words
          case [keyword, rest.size]
          in ['request', 2] then request << field(rest, child, kinds)
          in ['request', 3]
            request << field(rest.take(2), child, kinds)
            directories << directory_field(rest, child)
          in ['reply', 2] then reply << field(rest, child, kinds)
          in ['reply', 3]
            # A bad name, kind or attribute word is reported as such first.
            field(rest.take(2), child, kinds)
            directory_field(rest, child)
            child.fail!('only a request field can be a directory')
          in ['refused', 0] then refused = true
          in ['check', 3] then checks << rest
          in ['writes', 1..4]
            child.fail!('duplicate writes marker') if marker
            marker = rest
          else child.fail!('unknown operation member')
          end
        end
        line.fail!('a refused operation has no reply fields') if refused && !reply.empty?
        [request, reply].each do |fields|
          line.fail!('duplicate field') unless fields.map(&:first).uniq.size == fields.size
          line.fail!('too many fields') if fields.size > MAX_FIELDS
        end
        { name: name, type: type, request: request.freeze, reply: refused ? nil : reply.freeze,
          directories: directories.freeze,
          checks: checks.map { |item| check(item, line, request, reply, kinds) }.freeze,
          writes: writes(marker, line, request, constants) }.freeze
      end

      def field(words, line, kinds)
        [atom_name(words[0], line: line), known_kind(words[1], line, kinds)].freeze
      end

      # NAME KIND directory: a fid that must name a directory. The generated
      # directory_fids/1 lists it, so a server refuses a request whose fid there
      # names anything else from the table, not from a list of its own.
      def directory_field(words, line)
        name, kind_name, attribute = words
        line.fail!("unknown field attribute #{attribute}") unless attribute == 'directory'
        unless kind_name == DIRECTORY_KIND
          line.fail!("only a field of kind #{DIRECTORY_KIND} can be a directory, not #{kind_name}")
        end
        name
      end

      def check(words, line, request, reply, kinds)
        left, relation, right = words
        line.fail!('unknown check relation') unless RELATIONS.include?(relation)
        { reply: measured(left, reply, line, kinds), relation: relation,
          request: measured(right, request, line, kinds) }.freeze
      end

      # FIELD.MEASURE, where the measure must apply to the field's kind.
      def measured(word, fields, line, kinds)
        name, measure, extra = word.split('.')
        line.fail!("expected FIELD.MEASURE, not #{word}") unless measure && extra.nil? && MEASURES.include?(measure)
        kind_name = fields.to_h.fetch(name) { line.fail!("check names no field #{name}") }
        kind = kinds[kind_name]
        form = kind ? kind.fetch(:form) : 'integer'
        fits = case measure
               when 'value' then form == 'integer' && !(kind && kind[:atom]) && kind_name != 'alias'
               when 'bytes' then form == 'text'
               when 'length' then form == 'list'
               when 'packed' then form == 'list' && kind.key?(:packed)
               end
        line.fail!("measure #{measure} does not apply to #{name}") unless fits
        { field: name, measure: measure, kind: kind_name }.freeze
      end

      def writes(words, line, request, constants)
        return nil unless words

        fields = request.to_h
        case words
        in ['always'] then { rule: 'always' }.freeze
        in ['any', field, *masks] if fields[field] == 'u32' && !masks.empty?
          { rule: 'any', field: field, masks: masks.map { |mask| number(mask, (1 << 32) - 1, line, constants) }.freeze }.freeze
        in ['equal', field, value] if INTEGER_BITS.key?(fields[field])
          maximum = (1 << INTEGER_BITS.fetch(fields[field])) - 1
          { rule: 'equal', field: field, value: number(value, maximum, line, constants) }.freeze
        else line.fail!('writes is always, any U32FIELD MASK... or equal FIELD N')
        end
      end

      def atom_name(word, line:)
        name = Syntax.identifier(word, line: line)
        line.fail!("#{name} is not a plain Erlang atom") if name.include?('.') || ERLANG_RESERVED.include?(name)
        name
      end

      def known_kind(word, line, kinds)
        name = atom_name(word, line: line)
        line.fail!("unknown kind #{name}") unless BASE_KINDS.include?(name) || kinds.key?(name)
        name
      end

      # A number keeps the limit it names, so generated code can say ?P9_IO_MAX
      # rather than 65536.
      def number(word, maximum, line, constants)
        value = Model.numeric(word, constants, line)
        line.fail!("value #{value} outside 0..#{maximum}") unless value.between?(0, maximum)
        { value: value, constant: word.start_with?('@') ? word.delete_prefix('@') : nil }.freeze
      end

      # Every kind an operation reaches, directly or through another kind.
      def used_kinds(kinds, operations)
        pending = operations.flat_map { |item| item.fetch(:request) + (item.fetch(:reply) || []) }.map(&:last)
        seen = []
        until pending.empty?
          name = pending.shift
          next if seen.include?(name) || BASE_KINDS.include?(name)

          seen << name
          kind = kinds.fetch(name)
          pending.concat(kind.fetch(:elements, []))
          pending << kind[:element] if kind[:element]
          pending.concat(kind.fetch(:fields, []).map(&:last))
        end
        seen
      end
    end
  end
end
