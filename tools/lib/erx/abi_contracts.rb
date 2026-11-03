# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'

module Erx
  module ABI
    FieldPath = Struct.new(:scope, :fields, :offset, :field, keyword_init: true) do
      def type
        field.type
      end
      def name
        ([scope == 'root' ? 'root' : "#{scope}[]"] + fields).join('.')
      end
    end

    # Reader rules name records explicitly. This pass closes each reference and
    # relation before the emitters can turn it into pointer or binary arithmetic.
    module Contracts
      STRING_CLASSES = %w[identifier dt_path namespace_path utf8 bytes args env].freeze
      module_function

      def reader(declaration, types:, constants:)
        Model.arity(declaration.line, 4)
        name, root_name, maximum = declaration.args
        root = types[root_name]
        declaration.fail!('reader root must have wire storage') unless root.is_a?(Layout) && root.storage == 'wire_le'
        validate_reader_shape(root, declaration.line)
        maximum = Model.reference(maximum, constants, declaration.line)
        declaration.fail!('reader byte bound is smaller than its header') if maximum < root.size
        tables = {}
        strings = {}
        rules = []
        order = nil
        source_role = nil
        extent = nil

        # The declaration order is not evaluation order. Tables are collected
        # first so a rule can reference a table declared later in the source.
        declaration.members.each do |line|
          next unless line.indent == 2 && %w[table string_table].include?(line.words.first)
          if line.words.first == 'table'
            Model.arity(line, 7)
            _, table_name, type_name, offset, count, bound, alignment = line.words
            type = types[type_name]
            line.fail!('table element must have a fixed wire layout') unless type.is_a?(Layout) && type.storage == 'wire_le' && !type.tail
            validate_reader_shape(type, line)
            bound = Model.reference(bound, constants, line)
            alignment = Model.power_of_two(alignment, line)
            line.fail!('table bound is zero or exceeds reader extent') unless bound.positive? && bound <= maximum / type.size
            line.fail!('table alignment is too small') if alignment < type.alignment
            target = tables
            record = { name: table_name, type: type, offset: offset, count: count,
                       maximum: bound, alignment: alignment, line: line }
          else
            Model.arity(line, 5)
            _, table_name, offset, count, bound = line.words
            bound = Model.reference(bound, constants, line)
            line.fail!('string table bound exceeds reader extent') if bound > maximum
            target = strings
            record = { name: table_name, offset: offset, count: count,
                       maximum: bound, alignment: 1, line: line }
          end
          Names.local(table_name, line: line)
          line.fail!('reader table cannot replace the root scope') if table_name == 'root'
          line.fail!('duplicate reader table') if tables.key?(table_name) || strings.key?(table_name)
          record[:offset_path] = field_path(offset, root: root, tables: {}, line: line)
          record[:count_path] = field_path(count, root: root, tables: {}, line: line)
          unsigned_path(record.fetch(:offset_path), line)
          unsigned_path(record.fetch(:count_path), line)
          target[table_name] = record.freeze
        end

        choice = nil
        declaration.members.each do |line|
          keyword, *words = line.words
          if line.indent == 4
            line.fail!('nested reader member must be a choice case') unless choice && keyword == 'case'
            Model.arity(line, 3)
            tag_name, active = words
            tag = choice.fetch(:enum).members[tag_name]
            line.fail!('unknown or duplicate choice tag') unless tag && !choice.fetch(:cases).key?(tag)
            fields = parse_paths(active, root: root, tables: tables, line: line)
            line.fail!('active field is outside choice') unless (fields.map(&:name) - choice.fetch(:fields).map(&:name)).empty?
            choice.fetch(:cases)[tag] = fields.freeze
            next
          end
          choice = nil
          guard = nil
          if words.include?('when')
            unless %w[value range index string].include?(keyword) && words[-3] == 'when' && words.count('when') == 1
              line.fail!('when requires a value, range, index or string rule and one tag/member pair')
            end
            tag = field_path(words[-2], root: root, tables: tables, line: line)
            unless tag.type.is_a?(EnumType) && !tag.type.flags && !tag.field.array? && tag.type.members.key?(words[-1])
              line.fail!('when tag must be a scalar closed enumeration and declared member')
            end
            guard = { tag: tag, value: tag.type.members.fetch(words[-1]) }.freeze
            words = words.take(words.size - 3)
          end
          case keyword
          when 'table', 'string_table'
            next
          when 'order'
            line.fail!('duplicate table order') if order
            order = words.freeze
          when 'source'
            Model.arity(line, 2)
            line.fail!('duplicate input source role') if source_role
            source_role = Syntax.identifier(words[0], line: line)
          when 'extent'
            Model.arity(line, 2)
            line.fail!('duplicate reader extent') if extent
            extent = field_path(words[0], root: root, tables: {}, line: line)
            unsigned_path(extent, line)
          when 'value', 'range'
            line.fail!('invalid value/range rule') unless words.size == (keyword == 'value' ? 2 : 3)
            path = field_path(words[0], root: root, tables: tables, line: line)
            line.fail!('value/range requires an integer scalar') unless path.type.respond_to?(:integer) && !path.field.array?
            numbers = words.drop(1).map do |word|
              Model.numeric(word, constants, line)
            end
            base = path.type.integer
            line.fail!('constraint is outside field type') unless numbers.all? { |value| value.between?(base.minimum, base.maximum) }
            line.fail!('range is inverted') if keyword == 'range' && numbers[0] > numbers[1]
            rules << { kind: keyword, path: path, values: numbers.freeze, line: line }.freeze
          when 'index'
            line.fail!('index requires FIELD TABLE [absent VALUE]') unless [2, 4].include?(words.size) && (words.size == 2 || words[2] == 'absent')
            path = field_path(words[0], root: root, tables: tables, line: line)
            unsigned_path(path, line)
            table = tables[words[1]] || line.fail!('index target is not a declared record table')
            absent = words.size == 4 ? Model.unsigned(words[3], line, maximum: path.type.integer.maximum) : nil
            line.fail!('absent index can name a valid record') if absent && absent < table.fetch(:maximum)
            rules << { kind: keyword, path: path, table: table.fetch(:name), absent: absent, line: line }.freeze
          when 'slice', 'partition', 'string'
            expected = keyword == 'string' ? [5, 7] : [3]
            line.fail!("invalid #{keyword} rule") unless expected.include?(words.size)
            offset = field_path(words[0], root: root, tables: tables, line: line)
            count = field_path(words[1], root: root, tables: tables, line: line)
            same_scope([offset, count], line)
            unsigned_path(offset, line)
            unsigned_path(count, line)
            target = keyword == 'string' ? strings[words[2]] : tables[words[2]]
            line.fail!("#{keyword} target has the wrong table kind") unless target
            record = { kind: keyword, offset: offset, count: count,
                       table: target.fetch(:name), line: line }
            if keyword == 'partition' && (offset.scope == 'root' || offset.scope == target.fetch(:name))
              line.fail!('partition owner must be a different record table')
            end
            if keyword == 'string'
              line.fail!('unknown string class') unless STRING_CLASSES.include?(words[3])
              record[:class] = words[3]
              record[:maximum] = Model.reference(words[4], constants, line)
              record[:empty] = false
              if words.size == 7
                line.fail!('string empty option must be yes or no') unless words[5] == 'empty' && %w[yes no].include?(words[6])
                record[:empty] = words[6] == 'yes'
              end
              line.fail!('string bound exceeds its table') if record.fetch(:maximum) > target.fetch(:maximum)
            end
            rules << record.freeze
          when 'optional'
            Model.arity(line, 4)
            path = field_path(words[0], root: root, tables: tables, line: line)
            flags = field_path(words[1], root: root, tables: tables, line: line)
            same_scope([path, flags], line)
            type = flags.type
            unless type.is_a?(EnumType) && type.flags && type.members.key?(words[2])
              line.fail!('optional needs a declared flag bit')
            end
            line.fail!('field cannot control its own presence') if path.name == flags.name
            rules << { kind: keyword, path: path, flags: flags,
                       mask: type.members.fetch(words[2]), line: line }.freeze
          when 'choice'
            Model.arity(line, 4)
            tag = field_path(words[0], root: root, tables: tables, line: line)
            enum = types[words[1]]
            line.fail!('choice tag must name a closed enumeration') unless enum.is_a?(EnumType) && !enum.flags && tag.type.respond_to?(:integer) && !tag.field.array?
            unless enum.members.values.all? { |value| value.between?(tag.type.integer.minimum, tag.type.integer.maximum) }
              line.fail!('choice enumeration does not fit tag field')
            end
            fields = parse_paths(words[2], root: root, tables: tables, line: line)
            same_scope([tag] + fields, line)
            line.fail!('choice fields must be nonempty and exclude tag') if fields.empty? || fields.any? { |path| path.name == tag.name }
            choice = { kind: keyword, tag: tag, enum: enum, fields: fields.freeze,
                       cases: {}, line: line }
            rules << choice
          else line.fail!("unknown reader rule #{keyword}")
          end
          if guard
            rule = rules.pop
            path = rule[:path] || rule.fetch(:offset)
            same_scope([path, guard.fetch(:tag)], line)
            rules << rule.merge(guard: guard).freeze
          end
        end
        expected_order = tables.keys + strings.keys
        order ||= []
        unless order.sort == expected_order.sort && order.uniq.size == order.size
          declaration.fail!('table order must name every table exactly once')
        end
        declaration.fail!('record tables must precede string tables') unless order.take(tables.size).sort == tables.keys.sort
        rules.each do |rule|
          next unless rule.fetch(:kind) == 'choice'
          unless rule.fetch(:cases).keys.sort == rule.fetch(:enum).members.values.sort
            rule.fetch(:line).fail!('choice does not cover every tag')
          end
          rule.fetch(:cases).freeze
          rule.freeze
        end
        partitions = rules.select { |rule| rule.fetch(:kind) == 'partition' }
        unless partitions.map { |rule| rule.fetch(:table) }.uniq.size == partitions.size
          declaration.fail!('a partition target has more than one owner declaration')
        end
        input_fields = ([root] + tables.values.map { |table| table.fetch(:type) }).flat_map do |layout|
          Model.leaf_fields(layout).values.select { |field| !field.input_masks.empty? }
        end
        if source_role
          input_fields.each do |field|
            declaration.fail!("input role has no mask for #{field.name}") unless field.input_masks.key?(source_role)
          end
        elsif input_fields.any?
          declaration.fail!('reader must select an input role')
        end
        Reader.new(name: name, root: root, maximum: maximum,
                   tables: tables.freeze, strings: strings.freeze,
                   rules: rules.freeze, order: (order || []).freeze,
                   source_role: source_role, extent: extent, line: declaration.line).freeze
      end

      def field_path(text, root:, tables:, line:)
        match = text&.match(/\A(root|[a-z][a-z0-9_]*\[\])\.([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)\z/)
        line.fail!("invalid field path #{text}") unless match
        scope = match[1] == 'root' ? 'root' : match[1].delete_suffix('[]')
        type = scope == 'root' ? root : tables[scope]&.fetch(:type)
        line.fail!("unknown field scope #{scope}") unless type
        names = match[2].split('.')
        offset = 0
        field = nil
        names.each_with_index do |name, index|
          line.fail!('field path traverses a scalar') unless type.is_a?(Layout)
          field = type.fields.find { |item| item.name == name }
          line.fail!("undefined field #{text}") unless field
          offset += field.offset
          if index + 1 < names.size && field.array?
            line.fail!('field path cannot traverse an array')
          end
          type = field.type
        end
        FieldPath.new(scope: scope.freeze, fields: names.freeze, offset: offset,
                      field: field).freeze
      end

      def validate_reader_shape(layout, line)
        pending = [layout]
        seen = {}
        until pending.empty?
          type = pending.pop
          next if seen[type.name]
          seen[type.name] = true
          line.fail!('whole readers require fixed records and named bounded tables, not layout tails') if type.tail
          type.fields.each do |field|
            next unless field.type.is_a?(Layout)
            line.fail!('nested record arrays need a named bounded reader table') if field.array?
            pending << field.type
          end
        end
      end

      def unsigned_path(path, line)
        unless path.type.respond_to?(:integer) && !path.type.integer.signed && !path.field.array?
          line.fail!("#{path.name} must be an unsigned scalar")
        end
      end

      def same_scope(paths, line)
        line.fail!('rule mixes record scopes') unless paths.map(&:scope).uniq.size == 1
      end

      def parse_paths(value, root:, tables:, line:)
        return [] if value == 'none'
        paths = value.split(',').map { |path| field_path(path, root: root, tables: tables, line: line) }
        line.fail!('duplicate field path') unless paths.map(&:name).uniq.size == paths.size
        paths
      end

      # The executor rule: allow, refuse, or private ARG, which admits an
      # executor only on a word of its own private memory that ARG names.
      EXECUTOR_RULES = %w[allow refuse private].freeze
      UTCB_LAYOUT = 'erx_utcb'
      UTCB_WORDS_FIELD = 'mr'

      def calls(declarations, types:, constants:, objects:, rights:)
        calls = declarations.to_h do |declaration|
          Model.arity(declaration.line, 3)
          [declaration.args.first, call_contract(declaration, types: types, constants: constants,
                                        objects: objects, rights: rights)]
        end
        if calls.any?
          Model.unique_values(calls.transform_values { |call| call.fetch(:number) }, label: 'call', line: declarations.first.line)
        end
        calls.sort.to_h
      end

      def call_contract(declaration, types:, constants:, objects:, rights:)
        properties = {}
        executor = nil
        retry_lookup = false
        arguments = []
        results = []
        bounds = {}
        windows = []
        declaration.members.each do |line|
          line.fail!('call members cannot be nested') unless line.indent == 2
          keyword, *words = line.words
          case keyword
          when 'waits', 'effects', 'charges'
            Model.arity(line, 2)
            line.fail!('duplicate call property') if properties.key?(keyword)
            properties[keyword] = words[0]
          when 'executor'
            line.fail!('duplicate call property') if executor
            unless EXECUTOR_RULES.include?(words[0]) && words.size == (words[0] == 'private' ? 2 : 1)
              line.fail!('executor needs allow, refuse or private ARGUMENT')
            end
            executor = { rule: words[0], argument: words[1], line: line }
          when 'retry'
            Model.arity(line, 1)
            line.fail!('duplicate retry member') if retry_lookup
            retry_lookup = true
          when 'bound'
            Model.arity(line, 3)
            unit, value = words
            Syntax.identifier(unit, line: line)
            line.fail!('duplicate work bound') if bounds.key?(unit)
            bounds[unit] = Model.reference(value, constants, line)
            line.fail!('work bound must be positive') unless bounds.fetch(unit).positive?
          when 'arg', 'result'
            parameter = call_parameter(words, line, types: types, objects: objects,
                                       rights: rights, result: keyword == 'result')
            (keyword == 'arg' ? arguments : results) << parameter
          when 'window'
            Model.arity(line, 7)
            window_name, cap, offset, length, direction, maximum = words
            line.fail!('invalid window direction') unless %w[read write].include?(direction)
            windows << { name: window_name, cap: cap, offset: offset, length: length,
                         direction: direction, maximum: Model.reference(maximum, constants, line), line: line }.freeze
          else line.fail!("unknown call member #{keyword}")
          end
        end
        unless properties.keys.sort == %w[charges effects waits] && executor && bounds.any?
          declaration.fail!('call needs waits, executor, effects, charges and a bound')
        end
        { 'waits' => %w[yes no], 'effects' => %w[reads changes] }.each do |key, allowed|
          declaration.fail!("invalid #{key} property") unless allowed.include?(properties.fetch(key))
        end
        waits = properties.fetch('waits') == 'yes'
        [arguments, results].each { |parameters| validate_locations(parameters, declaration) }
        # The dispatch takes at most two existence locks, together, and a
        # result is returned to the caller, never looked up.
        declaration.fail!('a call holds at most two existence locks') if arguments.count { |argument| argument.fetch(:exists) } > 2
        declaration.fail!('a result cannot hold an existence lock') if results.any? { |result| result.fetch(:exists) }
        validate_executor(executor, arguments, waits: waits)
        if retry_lookup && !(waits && arguments.any? { |argument| argument[:object] })
          declaration.fail!('retry needs a waiting call with a capability argument to look up again')
        end
        declaration.fail!('waiting call cannot have windows') if waits && windows.any?
        charge = properties.fetch('charges')
        declaration.fail!('charged argument is not a capability') unless charge == 'none' || arguments.any? { |arg| arg.fetch(:name) == charge && arg[:object] }
        windows.each { |window| validate_window(window, arguments, properties, constants, rights, declaration) }
        { number: Model.positive(declaration.args[1], declaration.line, maximum: (1 << 32) - 1),
          properties: properties.freeze, executor: executor.except(:line).freeze,
          retry: retry_lookup, arguments: arguments.freeze, results: results.freeze,
          bounds: bounds.freeze, windows: windows.freeze }.freeze
      end

      # The dispatch refuses an executor by its class only before a wait. A
      # call that never waits is `allow`; one that an executor may not use in
      # some form fails in its handler with that call's own status.
      def validate_executor(executor, arguments, waits:)
        line = executor.fetch(:line)
        line.fail!('a call that does not wait must allow executors') if !waits && executor.fetch(:rule) != 'allow'
        return unless executor.fetch(:rule) == 'private'
        word = arguments.find { |argument| argument.fetch(:name) == executor.fetch(:argument) }
        unless word && word.fetch(:location) == 'register' && !word[:object] && word.fetch(:type).integer == Model::BASE_TYPES.fetch('u64')
          line.fail!('private executor rule must name a u64 register word that is not a capability')
        end
      end

      # A register holds one parameter, so the register index bounds their
      # count. A UTCB parameter owns whole message words that no other
      # parameter of the same direction shares.
      def validate_locations(parameters, declaration)
        unless parameters.map { |parameter| parameter.fetch(:name) }.uniq.size == parameters.size
          declaration.fail!('duplicate parameter name')
        end
        registers = parameters.select { |parameter| parameter.fetch(:location) == 'register' }
        unless registers.map { |parameter| parameter.fetch(:slot) }.uniq.size == registers.size
          declaration.fail!('duplicate parameter register')
        end
        parameters.select { |parameter| parameter.fetch(:location) == 'utcb' }
                  .sort_by { |parameter| parameter.fetch(:slot) }
                  .each_cons(2) do |left, right|
          declaration.fail!('UTCB parameter words overlap') if left.fetch(:slot) + left.fetch(:words) > right.fetch(:slot)
        end
      end

      # The dispatch looks a window's capability up with its declared rights
      # alone, so those rights include the one the window's direction needs:
      # a holder without it cannot have the kernel read or write the object.
      def validate_window(window, arguments, properties, constants, rights, declaration)
        cap = arguments.find { |arg| arg.fetch(:name) == window.fetch(:cap) }
        declaration.fail!('window needs a memory capability') unless cap && cap[:object] == 'memory'
        needed = window.fetch(:direction)
        unless (cap.fetch(:rights) & rights.fetch(needed, 0)) != 0
          declaration.fail!("window capability needs the #{needed} right")
        end
        # A window's size is checked at its lookup, which an existence lock
        # would then pass a preemption point after.
        declaration.fail!('window capability cannot hold an existence lock') if cap.fetch(:exists)
        %i[offset length].each do |field|
          argument = arguments.find { |arg| arg.fetch(:name) == window.fetch(field) }
          declaration.fail!('window offset/length is not an unsigned argument') unless argument && argument.fetch(:type).respond_to?(:integer) && !argument.fetch(:type).integer.signed
        end
        copy_max = constants['copy_max'] || declaration.fail!('window needs copy_max limit')
        declaration.fail!('window exceeds copy_max') if window.fetch(:maximum) > copy_max.value
        declaration.fail!('written window requires reads-only effects') if window.fetch(:direction) == 'write' && properties.fetch('effects') != 'reads'
      end

      def call_parameter(words, line, types:, objects:, rights:, result:)
        name = Names.local(words[0], line: line)
        remaining = words.drop(1)
        object = nil
        mask = 0
        if remaining.first == 'cap'
          line.fail!('capability argument needs type, rights and location') unless [5, 6].include?(remaining.size)
          _, object, required, *remaining = remaining
          type = types['cap'] || line.fail!('capability parameter needs scalar cap declaration')
          object_type = objects[object] || line.fail!('undefined capability type')
          selected = Model.list(required, line)
          line.fail!('required right is outside capability type') unless (selected - object_type.fetch(:sets).fetch('rights')).empty?
          mask = selected.reduce(0) { |value, right| value | rights.fetch(right) }
        else
          type_name, *remaining = remaining
          type = types[type_name] || line.fail!("undefined parameter type #{type_name}")
        end
        location, slot, existence = remaining
        line.fail!('invalid parameter location') unless [2, 3].include?(remaining.size) && %w[register utcb].include?(location)
        line.fail!('exists is valid only on a capability') if existence && (existence != 'exists' || !object)
        if location == 'register'
          slot = Model.unsigned(slot, line, maximum: result ? 1 : 5)
          line.fail!('register parameter is not one integer word') unless type.respond_to?(:integer)
          words = 1
        else
          slot, words = utcb_extent(slot, type, line, types: types)
          line.fail!('an aggregate argument cannot carry a capability') if !result && !object && carries_capability?(type)
        end
        { name: name, type: type, object: object, rights: mask,
          location: location, slot: slot, words: words, exists: !!existence, line: line }.freeze
      end

      # A capability in an aggregate has no declared type or rights, so the
      # admission plan could not list it and nothing here says what checks
      # it. The declared scalar named cap is what makes a value a capability.
      def carries_capability?(type)
        return false unless type.is_a?(Layout)

        type.fields.any? { |field| field.type.name == 'cap' || carries_capability?(field.type) }
      end

      # A UTCB parameter starts at message word INDEX of the declared UTCB
      # layout, spelled mr[INDEX], and owns every word its type touches; all
      # of them lie inside the message words.
      def utcb_extent(field, type, line, types:)
        utcb = types[UTCB_LAYOUT]
        words = utcb.is_a?(Layout) && utcb.fields.find { |item| item.name == UTCB_WORDS_FIELD }
        unless words && words.array? && words.type == Model::BASE_TYPES.fetch('u64') &&
               words.atomic && words.atomic.fetch(:store) != 'none'
          line.fail!("UTCB parameter needs layout #{UTCB_LAYOUT} with atomic u64 words #{UTCB_WORDS_FIELD}")
        end
        match = field&.match(/\A#{UTCB_WORDS_FIELD}\[(0|[1-9][0-9]{0,3})\]\z/o)
        line.fail!("UTCB location must be #{UTCB_WORDS_FIELD}[INDEX]") unless match
        index = Integer(match[1], 10)
        validate_utcb_type(type, line)
        count = (type.size + 7) / 8
        line.fail!('UTCB parameter extends beyond the message words') unless index + count <= words.count
        [index, count]
      end

      # An aggregate is decoded leaf by leaf from a kernel copy of its words,
      # so every leaf is an integer or fixed bytes inside a wire layout.
      def validate_utcb_type(type, line)
        case type
        when Layout
          unless type.storage == 'wire_le' && !type.tail && !type.sequence
            line.fail!('UTCB aggregate must be a fixed wire layout without a tail or sequence')
          end
          type.fields.each do |field|
            line.fail!('UTCB aggregate field cannot be atomic or role-masked') if field.atomic || !field.input_masks.empty?
            validate_utcb_type(field.type, line)
          end
        when BytesType
          line.fail!('UTCB bytes cannot have a fixed value') if type.fixed
        else
          line.fail!('UTCB parameter must be an integer, fixed bytes or a layout') unless type.respond_to?(:integer)
        end
      end

      def translations(declarations, types:)
        declarations.map do |declaration|
          Model.arity(declaration.line, 4)
          name, source_name, target_name = declaration.args
          source = types[source_name]
          target = types[target_name]
          declaration.fail!('translation requires closed source/target enumerations') unless [source, target].all? { |type| type.is_a?(EnumType) && !type.flags }
          mappings = {}
          declaration.members.each do |line|
            Model.arity(line, 3)
            operation, from, to = line.words
            line.fail!('unknown or duplicate translation source') unless source.members.key?(from) && !mappings.key?(from)
            line.fail!('unknown translation operation') unless %w[map omit].include?(operation)
            line.fail!('unknown translation target') if operation == 'map' && !target.members.key?(to)
            mappings[from] = { operation: operation, value: to }.freeze
          end
          declaration.fail!('incomplete translation') unless mappings.keys.sort == source.members.keys.sort
          { name: name, source: source_name, target: target_name, mappings: mappings.freeze }.freeze
        end.freeze
      end

      def services(declarations)
        seen_numbers = {}
        declarations.map do |declaration|
          Model.arity(declaration.line, 3)
          name, number = declaration.args
          number = Model.positive(number, declaration.line, maximum: (1 << 32) - 1)
          declaration.fail!('duplicate service interface number') if seen_numbers.key?(number)
          seen_numbers[number] = name
          operations = {}
          parameters = {}
          liveness = nil
          declaration.members.each do |line|
            keyword, *words = line.words
            case keyword
            when 'operation'
              Model.arity(line, 3)
              operation, id = words
              Syntax.identifier(operation, line: line)
              line.fail!('duplicate operation') if operations.key?(operation)
              operations[operation] = Model.positive(id, line, maximum: (1 << 32) - 1)
            when 'liveness'
              Model.arity(line, 2)
              line.fail!('duplicate liveness marker') if liveness
              liveness = words[0]
            when 'parameter'
              key, id, kind, cardinality, *bound = words
              allowed = %w[u64 i64 boolean identifier namespace_path domain principal device bytes]
              line.fail!('invalid parameter kind or duplicate key') unless allowed.include?(kind) && !parameters.key?(key)
              Syntax.identifier(key, line: line)
              count = cardinality == 'set' ? Model.positive(bound.shift, line, maximum: 65536) : 1
              line.fail!('unknown parameter cardinality') unless %w[one optional set].include?(cardinality)
              marker = bound.index('checked_by')
              line.fail!('parameter requires one checked_by helper') unless marker && marker == bound.size - 2
              helper = Syntax.identifier(bound.last, line: line)
              constraint = bound.take(marker)
              validate_parameter_constraint(kind, constraint, line)
              parameters[key] = { number: Model.positive(id, line, maximum: (1 << 32) - 1),
                                  kind: kind, cardinality: cardinality, maximum_count: count,
                                  bound: constraint.freeze, helper: helper }.freeze
            else line.fail!('unknown service metadata member')
            end
          end
          declaration.fail!('liveness must name a declared operation') if liveness && !operations.key?(liveness)
          Model.unique_values(operations, label: 'operation', line: declaration.line)
          Model.unique_values(parameters.transform_values { |value| value.fetch(:number) }, label: 'parameter', line: declaration.line)
          { name: name, number: number,
            operations: operations.freeze, parameters: parameters.freeze, liveness: liveness }.freeze
        end.freeze
      end

      def validate_parameter_constraint(kind, constraint, line)
        case kind
        when 'u64', 'i64'
          line.fail!('integer parameter requires range MIN MAX') unless constraint.size == 3 && constraint[0] == 'range'
          base = Model::BASE_TYPES.fetch(kind)
          low, high = constraint.drop(1).map { |word| Syntax.integer(word, line: line) }
          line.fail!('parameter range is invalid') unless low <= high && low >= base.minimum && high <= base.maximum
        when 'identifier', 'namespace_path', 'bytes'
          line.fail!('byte parameter requires bytes MAX') unless constraint.size == 2 && constraint[0] == 'bytes'
          Model.positive(constraint[1], line, maximum: 4 * 1024 * 1024)
        when 'boolean'
          line.fail!('boolean parameter requires boolean bound') unless constraint == ['boolean']
        else
          table = { 'domain' => 'domains', 'principal' => 'principals', 'device' => 'devices' }.fetch(kind)
          valid = kind == 'domain' ? constraint.size == 4 && constraint[2] == 'system' && %w[yes no].include?(constraint[3]) : constraint.size == 2
          line.fail!('reference parameter has an invalid target') unless valid && constraint[0] == 'target' && constraint[1] == table
        end
      end
    end
  end
end
