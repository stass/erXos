# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'
require_relative 'abi_names'

module Erx
  module ABI
    IntegerType = Struct.new(:name, :size, :alignment, :signed, keyword_init: true) do
      def bits
        size * 8
      end
      def minimum
        signed ? -(1 << (bits - 1)) : 0
      end
      def maximum
        signed ? (1 << (bits - 1)) - 1 : (1 << bits) - 1
      end
      def integer
        self
      end
      def strong?
        false
      end
    end

    ScalarType = Struct.new(:name, :base, :minimum, :maximum, :multiple,
                            keyword_init: true) do
      def size
        base.size
      end
      def alignment
        base.alignment
      end
      def integer
        base
      end
      def strong?
        true
      end
    end

    EnumType = Struct.new(:name, :base, :members, :flags, :allowed, keyword_init: true) do
      def size
        base.size
      end
      def alignment
        base.alignment
      end
      def integer
        base
      end
      def strong?
        false
      end
      def mask
        members.values.reduce(0, :|)
      end
    end

    BytesType = Struct.new(:name, :size, :fixed, keyword_init: true) do
      def alignment
        1
      end
      def strong?
        false
      end
    end

    Field = Struct.new(:name, :type, :offset, :count, :bits, :atomic,
                       :writer, :owners, :zero_mask, :input_masks,
                       :visibility, :line, keyword_init: true) do
      def size
        type.size * (count || 1)
      end
      def array?
        !count.nil?
      end
    end
    Tail = Struct.new(:name, :type, :count_field, :maximum, :line,
                      keyword_init: true)
    Layout = Struct.new(:name, :version, :storage, :alignment, :size,
                        :fields, :padding, :tail, :sequence, :private_owner,
                        :line, keyword_init: true) do
      # A private layout's members are its owner's alone: private_owner is
      # the one source file the ABI file names as its owner, nil for a
      # public layout. Its definition, offsets and accessors go to its own
      # header, named after the layout without its erx_ prefix; the public
      # header declares only its tag, size and alignment.
      def private? = !private_owner.nil?
      def private_header = private? ? "kernel/generated/#{Names.stem(name)}_impl.h" : nil

      def fetch_field(name)
        fields.find { |field| field.name == name } || line.fail!("unknown field #{name}")
      end
      def strong?
        false
      end
    end
    Reader = Struct.new(:name, :root, :maximum, :tables, :strings, :rules,
                        :order, :source_role, :extent, :line, keyword_init: true)
    Constant = Struct.new(:name, :value, :type, :description, keyword_init: true)
    Schema = Struct.new(:version, :architecture, :types, :type_order,
                        :constants, :rights, :objects, :kinds, :caps, :calls,
                        :readers, :translations, :services, :projections,
                        :inputs, keyword_init: true)

    # Resolve types before readers and calls. No emitter receives an unchecked
    # declaration, and no output depends on hash insertion or include order.
    module Model
      TOP_LEVEL = %w[abi arch trap reg limit scalar enum flags bytes layout
                     status right type kind cap call reader translation service
                     projection].freeze
      TYPE_KINDS = %w[scalar enum flags bytes layout].freeze
      BASE_TYPES = [1, 2, 4, 8].flat_map do |size|
        [false, true].map do |signed|
          name = "#{signed ? 'i' : 'u'}#{size * 8}"
          [name, IntegerType.new(name: name.freeze, size: size,
                                 alignment: size, signed: signed).freeze]
        end
      end.to_h.freeze
      UINT64_MAX = (1 << 64) - 1
      MAX_LAYOUT_SIZE = 16 * 1024 * 1024
      MAX_TYPE_DEPTH = 64

      module_function

      def validate(source)
        declarations = source.declarations
        declarations.each do |declaration|
          declaration.fail!("unknown declaration #{declaration.kind}") unless TOP_LEVEL.include?(declaration.kind)
          declaration.line.tokens.drop(1).each_with_index do |token, index|
            next unless token.quoted
            allowed = %w[status right].include?(declaration.kind) && index == 2
            declaration.fail!('quoted token is not permitted here') unless allowed
          end
        end
        by_kind = declarations.group_by(&:kind)
        abi = exactly_one(by_kind, 'abi')
        arity(abi.line, 2)
        no_members(abi)
        version = unsigned(abi.args.first, abi.line, maximum: (1 << 32) - 1)
        abi.fail!('ABI version must be positive') if version.zero?
        architecture = validate_architecture(by_kind)
        definitions = unique_definitions(declarations)
        constants = collect_constants(by_kind)
        add_constant(constants, 'abi_version', version, BASE_TYPES.fetch('u32'), abi.line)
        types, type_order = resolve_types(definitions, constants)
        rights = by_kind.fetch('right', []).to_h do |declaration|
          arity(declaration.line, 4)
          no_members(declaration)
          position = unsigned(declaration.args[1], declaration.line, maximum: 31)
          [declaration.args[0], 1 << position]
        end
        unique_values(rights, label: 'right', line: abi.line)
        objects = validate_objects(by_kind.fetch('type', []), rights)
        kinds = validate_kinds(by_kind.fetch('kind', []), objects, rights)
        caps = validate_caps(by_kind.fetch('cap', []), objects, rights)
        calls = validate_calls(by_kind.fetch('call', []), types, constants, objects, rights)
        abi.fail!('calls require a complete architecture binding') if calls.any? && !architecture
        readers = by_kind.fetch('reader', []).map { |item| validate_reader(item, types, constants) }
        translations = validate_translations(by_kind.fetch('translation', []), types)
        services = validate_services(by_kind.fetch('service', []))
        projections = validate_projections(by_kind.fetch('projection', []), types)
        all_constants = constants.dup
        [type_constants(types), right_constants(rights)].each do |addition|
          addition.each do |name, value|
            abi.fail!("constant name collision #{name}") if all_constants.key?(name)
            all_constants[name] = value
          end
        end
        objects.each { |name, value| add_constant(all_constants, "k_#{name}", value.fetch(:number), BASE_TYPES.fetch('u32'), abi.line) }
        kinds.each { |name, value| add_constant(all_constants, "kind_#{name}", value.fetch(:number), BASE_TYPES.fetch('u32'), abi.line) }
        caps.each { |name, value| add_constant(all_constants, "root_slot_#{name}", value.fetch(:slot), BASE_TYPES.fetch('u32'), abi.line) }
        calls.each { |name, value| add_constant(all_constants, "call_#{name}", value.fetch(:number), BASE_TYPES.fetch('u32'), abi.line) }
        Names.validate(types: types, constants: all_constants, calls: calls,
                       readers: readers, architecture: architecture, line: abi.line)
        result = Schema.new(version: version, architecture: architecture, types: types.freeze,
                   type_order: type_order.freeze, constants: all_constants.sort.to_h.freeze,
                   rights: rights.freeze, objects: objects.freeze, kinds: kinds.freeze, caps: caps.freeze,
                   calls: calls.freeze, readers: readers.sort_by(&:name).freeze,
                   translations: translations.freeze, services: services.freeze,
                   projections: projections.freeze, inputs: source.inputs).freeze
        freeze_value(result)
      end

      def arity(line, count)
        line.fail!("expected #{count - 1} fields for #{line.words.first}") unless line.tokens.size == count
      end

      def no_members(declaration)
        declaration.fail!('declaration does not take members') unless declaration.members.empty?
      end

      def exactly_one(by_kind, kind)
        found = by_kind.fetch(kind, [])
        raise SchemaError, "exactly one #{kind} declaration is required" unless found.size == 1
        found.first
      end

      def unsigned(value, line, maximum: UINT64_MAX)
        number = Syntax.integer(value, line: line)
        line.fail!("integer is outside 0..#{maximum}") unless number.between?(0, maximum)
        number
      end

      def positive(value, line, maximum: UINT64_MAX)
        number = unsigned(value, line, maximum: maximum)
        line.fail!('value must be positive') if number.zero?
        number
      end

      def power_of_two(value, line)
        number = positive(value, line, maximum: MAX_LAYOUT_SIZE)
        line.fail!('alignment is not a power of two') unless (number & (number - 1)).zero?
        number
      end

      def integer_type(name, line)
        BASE_TYPES[name] || line.fail!("expected a fixed-width integer type, got #{name}")
      end

      def list(text, line)
        line.fail!('missing name list') unless text.is_a?(String)
        return [].freeze if text == 'none'
        values = text.split(',', -1)
        values.each { |name| Syntax.identifier(name, line: line) }
        line.fail!('duplicate list member') unless values.uniq.size == values.size
        values.freeze
      end

      def reference(value, constants, line)
        number = numeric(value, constants, line)
        line.fail!('numeric bound must be nonnegative') if number.negative?
        number
      end

      def numeric(value, constants, line)
        return Syntax.integer(value, line: line) unless value && value.start_with?('@')
        constant = constants[value.delete_prefix('@')]
        line.fail!("undefined numeric reference #{value}") unless constant
        constant.value
      end

      # Only values freshly built by validation reach this ownership boundary.
      # Traverse even frozen containers: a frozen array can still contain a
      # mutable path component which would invalidate a checked reference.
      def freeze_value(value)
        pending = [value]
        seen = {}
        until pending.empty?
          current = pending.pop
          next if seen[current.object_id]
          seen[current.object_id] = true
          case current
          when Hash
            current.each { |key, item| pending << key << item }
          when Array
            pending.concat(current)
          when Struct
            current.each_pair { |_name, item| pending << item }
          end
          current.freeze
        end
        value
      end

      def unique_values(values, label:, line:)
        line.fail!("duplicate #{label} number") unless values.values.uniq.size == values.size
      end

      def unique_definitions(declarations)
        definitions = {}
        declarations.each do |declaration|
          next if %w[abi arch trap reg].include?(declaration.kind)
          name = Syntax.identifier(declaration.args.first, line: declaration.line)
          declaration.fail!("duplicate definition #{name}") if definitions.key?(name) || BASE_TYPES.key?(name)
          definitions[name] = declaration
        end
        definitions.freeze
      end

      def collect_constants(by_kind)
        constants = {}
        by_kind.fetch('limit', []).each do |declaration|
          arity(declaration.line, 4)
          no_members(declaration)
          name, type_name, literal = declaration.args
          type = integer_type(type_name, declaration.line)
          value = Syntax.integer(literal, line: declaration.line)
          declaration.fail!('constant does not fit its type') unless value.between?(type.minimum, type.maximum)
          add_constant(constants, name, value, type, declaration.line)
        end
        statuses = {}
        by_kind.fetch('status', []).each do |declaration|
          arity(declaration.line, 4)
          no_members(declaration)
          name, literal, description = declaration.args
          value = Syntax.integer(literal, line: declaration.line)
          unless value.between?(-(1 << 31), 0) && (value.zero? == (name == 'ok'))
            declaration.fail!('status must be zero for ok or a negative i32 error')
          end
          statuses[name] = value
          c_name = name == 'ok' ? 'ok' : "e#{name}"
          add_constant(constants, c_name, value, BASE_TYPES.fetch('i32'), declaration.line,
                       description: description)
        end
        if statuses.any?
          unique_values(statuses, label: 'status', line: by_kind.fetch('status').first.line)
        end
        constants
      end

      def add_constant(constants, name, value, type, line, description: nil)
        line.fail!("constant name collision #{name}") if constants.key?(name)
        constants[name] = Constant.new(name: name.freeze, value: value, type: type,
                                       description: description&.freeze).freeze
      end

      def resolve_types(definitions, constants)
        pending = definitions.select { |_name, item| TYPE_KINDS.include?(item.kind) }
        dependencies = pending.to_h do |name, declaration|
          names = case declaration.kind
                  when 'scalar', 'enum', 'flags' then [declaration.args[1]]
                  when 'layout'
                    declaration.members.select { |line| %w[field tail].include?(line.words.first) }
                               .map { |line| line.words[2] }
                  else []
                  end
          names.each do |dependency|
            unless BASE_TYPES.key?(dependency) || pending.key?(dependency)
              declaration.fail!("undefined type #{dependency}")
            end
          end
          [name, names.uniq.reject { |dependency| BASE_TYPES.key?(dependency) }]
        end
        users = Hash.new { |hash, key| hash[key] = [] }
        dependencies.each { |name, names| names.each { |dependency| users[dependency] << name } }
        remaining = dependencies.transform_values(&:size)
        ready = remaining.select { |_name, count| count.zero? }.keys.sort.reverse
        types = BASE_TYPES.dup
        order = []
        depths = {}
        until ready.empty?
          name = ready.pop
          depth = 1 + (dependencies.fetch(name).map { |dependency| depths.fetch(dependency) }.max || 0)
          pending.fetch(name).fail!("by-value type depth exceeds #{MAX_TYPE_DEPTH}") if depth > MAX_TYPE_DEPTH
          depths[name] = depth
          types[name] = build_type(pending.fetch(name), types, constants)
          order << name
          users[name].sort.reverse_each do |user|
            remaining[user] -= 1
            ready << user if remaining[user].zero?
          end
        end
        if order.size != pending.size
          name = (pending.keys - order).sort.first
          pending.fetch(name).fail!('cyclic by-value type dependency')
        end
        [types, order]
      end

      def build_type(declaration, types, constants)
        case declaration.kind
        when 'scalar' then build_scalar(declaration, constants)
        when 'enum', 'flags' then build_enum(declaration)
        when 'bytes' then build_bytes(declaration)
        when 'layout' then build_layout(declaration, types, constants)
        end
      end

      def build_scalar(declaration, constants)
        name, base_name, *properties = declaration.args
        base = integer_type(base_name, declaration.line)
        no_members(declaration)
        minimum, maximum, multiple = base.minimum, base.maximum, 1
        seen = []
        until properties.empty?
          property = properties.shift
          declaration.fail!("duplicate scalar property #{property}") if seen.include?(property)
          seen << property
          case property
          when 'range'
            minimum = numeric(properties.shift, constants, declaration.line)
            maximum = numeric(properties.shift, constants, declaration.line)
          when 'align'
            multiple = power_of_two(properties.shift, declaration.line)
          else declaration.fail!("unknown scalar property #{property}")
          end
        end
        unless minimum <= maximum && minimum >= base.minimum && maximum <= base.maximum
          declaration.fail!('scalar range is outside its base type')
        end
        ScalarType.new(name: name, base: base, minimum: minimum,
                       maximum: maximum, multiple: multiple).freeze
      end

      def build_enum(declaration)
        arity(declaration.line, 3)
        name, base_name = declaration.args
        base = integer_type(base_name, declaration.line)
        flags = declaration.kind == 'flags'
        declaration.fail!('flags require an unsigned base') if flags && base.signed
        members = {}
        allowed = nil
        declaration.members.each do |line|
          if line.words.first == 'allow'
            arity(line, 2)
            line.fail!('allow is one closed flag-combination set') unless flags && !allowed
            allowed = line.words[1].split(',', -1).map do |literal|
              unsigned(literal, line, maximum: base.maximum)
            end
            line.fail!('empty or duplicate flag combination') if allowed.empty? || allowed.uniq.size != allowed.size
            next
          end
          arity(line, 3)
          keyword, member, literal = line.words
          expected = flags ? 'bit' : 'value'
          line.fail!("expected #{expected} member") unless line.indent == 2 && keyword == expected
          Syntax.identifier(member, line: line)
          line.fail!('duplicate enumeration member') if members.key?(member)
          value = Syntax.integer(literal, line: line)
          if flags
            line.fail!('flag position is outside its base') unless value.between?(0, base.bits - 1)
            value = 1 << value
          elsif !value.between?(base.minimum, base.maximum)
            line.fail!('enumeration value is outside its base')
          end
          members[member] = value
        end
        declaration.fail!('empty enumeration') if members.empty?
        unique_values(members, label: 'enumeration', line: declaration.line)
        if allowed && allowed.any? { |value| (value & ~members.values.reduce(0, :|)) != 0 }
          declaration.fail!('flag combination includes an undeclared bit')
        end
        EnumType.new(name: name, base: base, members: members.sort.to_h.freeze,
                     flags: flags, allowed: allowed&.sort&.freeze).freeze
      end

      def build_bytes(declaration)
        name, length, *fixed = declaration.args
        no_members(declaration)
        size = positive(length, declaration.line, maximum: MAX_LAYOUT_SIZE)
        value = nil
        unless fixed.empty?
          unless fixed.size == 2 && fixed[0] == 'value' && fixed[1].match?(/\A(?:[0-9a-fA-F]{2})+\z/)
            declaration.fail!('bytes accepts only value HEX_BYTES')
          end
          value = [fixed[1]].pack('H*').freeze
          declaration.fail!('fixed byte value has the wrong length') unless value.bytesize == size
        end
        BytesType.new(name: name, size: size, fixed: value).freeze
      end

      def build_layout(declaration, types, constants)
        arity(declaration.line, 6)
        name, version, storage, alignment, size = declaration.args
        declaration.fail!('unknown layout storage') unless %w[wire_le shared native].include?(storage)
        version = positive(version, declaration.line, maximum: 65535)
        alignment = power_of_two(alignment, declaration.line)
        size = positive(size, declaration.line, maximum: MAX_LAYOUT_SIZE)
        declaration.fail!('layout size is not aligned') unless (size % alignment).zero?
        fields = []
        padding = []
        tail = nil
        sequence = nil
        current_field = nil
        metadata = []
        private_owner = nil
        declaration.members.each do |line|
          keyword, *words = line.words
          if line.indent == 4
            line.fail!('nested member must be bits below a field') unless keyword == 'bits' && current_field
            current_field.fetch(:bits) << validate_bits(line, current_field.fetch(:type))
            next
          end
          case keyword
          when 'field'
            line.fail!('a field cannot follow a tail') if tail
            unless [3, 5].include?(words.size) && (words.size == 3 || words[3] == 'count')
              line.fail!('field requires NAME TYPE OFFSET [count COUNT]')
            end
            field_name = Names.local(words[0], line: line)
            type = types.fetch(words[1])
            line.fail!('variable layout cannot be embedded') if type.is_a?(Layout) && type.tail
            line.fail!('nested layout storage differs from its owner') if type.is_a?(Layout) && type.storage != storage
            line.fail!('a private layout cannot be embedded') if type.is_a?(Layout) && type.private?
            count = words.size == 5 ? reference(words[4], constants, line) : nil
            line.fail!('array count must be positive and bounded') if count && (!count.positive? || count > MAX_LAYOUT_SIZE)
            offset = unsigned(words[2], line, maximum: size)
            current_field = { name: field_name, type: type, offset: offset,
                              count: count, bits: [], line: line }
            fields << current_field
          when 'padding'
            arity(line, 3)
            padding << [unsigned(words[0], line, maximum: size), positive(words[1], line, maximum: size)].freeze
            current_field = nil
          when 'tail'
            arity(line, 5)
            line.fail!('duplicate tail') if tail
            tail = Tail.new(name: Names.local(words[0], line: line), type: types.fetch(words[1]),
                            count_field: words[2], maximum: reference(words[3], constants, line), line: line).freeze
            current_field = nil
          when 'sequence'
            arity(line, 8)
            line.fail!('duplicate sequence declaration') if sequence
            unless words[1] == 'terminal' && words[3] == 'exhaustion' && words[5] == 'recovery'
              line.fail!('invalid sequence declaration')
            end
            sequence = { field: words[0], terminal: unsigned(words[2], line),
                         exhaustion: words[4], recovery: words[6], line: line }.freeze
            current_field = nil
          when 'private'
            arity(line, 2)
            line.fail!('duplicate private declaration') if private_owner
            line.fail!('a wire layout is read by other parties and cannot be private') if storage == 'wire_le'
            private_owner = owner_source(words[0], line)
            current_field = nil
          when 'atomic', 'writer', 'owner', 'zero', 'input_mask', 'visibility'
            metadata << line
            current_field = nil
          else line.fail!("unknown layout member #{keyword}")
          end
        end
        validate_layout_extents(fields, padding, size: size, alignment: alignment, line: declaration.line)
        completed = attach_metadata(fields, metadata, storage: storage)
        if tail
          count_field = completed.find { |field| field.name == tail.count_field }
          unless count_field && count_field.type.respond_to?(:integer) && !count_field.type.integer.signed && !count_field.array?
            tail.line.fail!('tail count must name an unsigned scalar field')
          end
          tail.line.fail!('tail bound must be positive and fit its count') unless tail.maximum.positive? && tail.maximum <= count_field.type.integer.maximum
          tail.line.fail!('tail is misaligned or contains a variable layout') unless (size % tail.type.alignment).zero? && !(tail.type.is_a?(Layout) && tail.type.tail)
        end
        validate_sequence(sequence, completed, constants) if sequence
        if tail && tail.type.is_a?(Layout) && tail.type.private?
          tail.line.fail!('a private layout cannot be embedded')
        end
        Layout.new(name: name, version: version, storage: storage,
                   alignment: alignment, size: size, fields: completed.freeze,
                   padding: padding.freeze, tail: tail, sequence: sequence,
                   private_owner: private_owner,
                   line: declaration.line).freeze
      end

      # The owner of a private layout: one C source of erXos's own, by a
      # plain relative path, which the chokepoint rule generated for the
      # layout lets include its header.
      def owner_source(path, line)
        line.fail!('a private layout names its owner as a relative path to a C source') unless
          path.match?(%r{\A[a-z0-9_]+(?:/[a-z0-9_]+)*\.c\z})
        path
      end

      def validate_layout_extents(fields, padding, size:, alignment:, line:)
        names = fields.map { |field| field.fetch(:name) }
        line.fail!('duplicate layout field') unless names.uniq.size == names.size
        extents = fields.map do |field|
          type = field.fetch(:type)
          offset = field.fetch(:offset)
          unless (offset % type.alignment).zero? && alignment >= type.alignment
            field.fetch(:line).fail!('misaligned field')
          end
          [offset, type.size * (field.fetch(:count) || 1)]
        end + padding
        cursor = 0
        extents.sort.each do |offset, bytes|
          line.fail!('fields overlap, leave a gap or exceed the layout') unless offset == cursor && bytes <= size - cursor
          cursor += bytes
        end
        line.fail!('fields do not cover the declared layout') unless cursor == size
      end

      def validate_bits(line, type)
        words = line.words
        unless [4, 6].include?(words.size) && (words.size == 4 || words[4] == 'shift')
          line.fail!('bits requires NAME LOW HIGH [shift COUNT]')
        end
        line.fail!('bits require an integer field') unless type.respond_to?(:integer)
        name = Names.local(words[1], line: line)
        low = unsigned(words[2], line)
        high = unsigned(words[3], line)
        shift = words.size == 6 ? unsigned(words[5], line) : 0
        width = type.integer.bits
        line.fail!('invalid bit range or shift') unless low <= high && high < width && shift < width && high - low + 1 + shift <= width
        { name: name, low: low, high: high, shift: shift, line: line }.freeze
      end

      def attach_metadata(fields, metadata, storage:)
        assignments = fields.to_h { |field| [field.fetch(:name), {}] }
        metadata.each do |line|
          keyword, selector, *words = line.words
          array = selector&.end_with?('[]')
          name = array ? selector.delete_suffix('[]') : selector
          field = fields.find { |item| item.fetch(:name) == name }
          line.fail!("unknown metadata field #{selector}") unless field
          line.fail!('array metadata requires [] exactly for arrays') unless array == !field.fetch(:count).nil?
          values = assignments.fetch(name)
          key = %w[owner input_mask].include?(keyword) ? [keyword, words[0]] : keyword
          line.fail!("duplicate #{keyword} metadata") if values.key?(key)
          values[key] = [words.freeze, line]
        end
        fields.map do |raw|
          values = assignments.fetch(raw.fetch(:name))
          type = raw.fetch(:type)
          line = raw.fetch(:line)
          bits = raw.fetch(:bits)
          bits.each_with_index do |range, index|
            prior = bits.take(index)
            if prior.any? { |item| item.fetch(:name) == range.fetch(:name) || (item.fetch(:low) <= range.fetch(:high) && range.fetch(:low) <= item.fetch(:high)) }
              line.fail!('overlapping or duplicate bit range')
            end
          end
          atomic = validate_atomic(values['atomic'], type, storage)
          writer = validate_writer(values['writer'])
          owners = {}
          input_masks = {}
          values.each do |key, (words, origin)|
            next unless key.is_a?(Array)
            origin.fail!('owner/input_mask requires ROLE MASK') unless words.size == 2
            role = Syntax.identifier(words[0], line: origin)
            target = key[0] == 'owner' ? owners : input_masks
            target[role] = mask(words[1], type, origin)
          end
          zero_mask = values['zero'] ? mask_member(values.fetch('zero'), type) : 0
          visibility = validate_visibility(values['visibility'])
          if storage == 'shared' && type.respond_to?(:integer)
            line.fail!('shared integer needs atomic, writer, owner and visibility metadata') unless atomic && writer && !owners.empty? && visibility
          end
          covered = zero_mask
          owners.each_value do |owned|
            line.fail!('ownership masks overlap') unless (covered & owned).zero?
            covered |= owned
          end
          if owners.any?
            line.fail!('ownership masks do not cover the field') unless covered == (1 << (type.size * 8)) - 1
          end
          input_masks.each_value { |allowed| line.fail!('input mask includes reserved bits') unless (allowed & zero_mask).zero? }
          Field.new(**raw.merge(bits: bits.freeze, atomic: atomic, writer: writer,
                                owners: owners.freeze, zero_mask: zero_mask,
                                input_masks: input_masks.freeze, visibility: visibility)).freeze
        end
      end

      def mask(literal, type, line)
        line.fail!('masks require an integer or opaque bytes value') unless type.respond_to?(:integer) || type.is_a?(BytesType)
        maximum = (1 << (type.size * 8)) - 1
        return maximum if literal == 'all'
        line.fail!('opaque byte masks must be all') if type.is_a?(BytesType)
        unsigned(literal, line, maximum: maximum)
      end

      def mask_member(entry, type)
        words, line = entry
        line.fail!('zero requires one mask') unless words.size == 1
        mask(words[0], type, line)
      end

      def validate_atomic(entry, type, storage)
        return nil unless entry
        words, line = entry
        unless words.size == 4 && words[0] == 'load' && words[2] == 'store' &&
               %w[relaxed acquire seq_cst].include?(words[1]) && %w[none relaxed release seq_cst].include?(words[3])
          line.fail!('invalid atomic memory order declaration')
        end
        line.fail!('atomic field requires shared storage and a primitive integer') unless storage == 'shared' && type.is_a?(IntegerType)
        { load: words[1], store: words[3] }.freeze
      end

      def validate_writer(entry)
        return nil unless entry
        words, line = entry
        line.fail!('writer requires one serialization owner') unless words.size == 1
        Syntax.identifier(words[0], line: line)
      end

      def validate_visibility(entry)
        return nil unless entry
        words, line = entry
        line.fail!('invalid visibility') unless words.size == 1 && %w[internal release development].include?(words[0])
        words[0]
      end

      def validate_sequence(sequence, fields, constants)
        line = sequence.fetch(:line)
        field = fields.find { |item| item.name == sequence.fetch(:field) }
        unless field && field.atomic && !field.array? && field.type.respond_to?(:integer) && !field.type.integer.signed
          line.fail!('sequence counter must be one atomic unsigned integer')
        end
        line.fail!('sequence terminal does not fit') if sequence.fetch(:terminal) > field.type.integer.maximum
        status_name = sequence.fetch(:exhaustion).delete_prefix('@')
        status = constants["e#{status_name}"]
        line.fail!('sequence exhaustion must name an error status') unless status && status.value.negative? && status.description
        line.fail!('sequence status accessors require the ok status') unless constants['ok'] && constants['ok'].description
        line.fail!('invalid sequence recovery') unless %w[none new_object new_incarnation].include?(sequence.fetch(:recovery))
      end

      def constant_prefix(name)
        name.delete_prefix('erx_').sub(/_(?:flags|kind)\z/, '')
      end

      def type_constants(types)
        constants = {}
        types.each_value do |type|
          next unless type.is_a?(EnumType)
          type.members.each do |name, value|
            key = "#{constant_prefix(type.name)}_#{name}"
            raise SchemaError, "generated constant collision #{key}" if constants.key?(key)
            constants[key] = Constant.new(name: key.freeze, value: value, type: type.base).freeze
          end
        end
        constants
      end

      def right_constants(rights)
        rights.to_h do |name, value|
          key = "hr_#{name}"
          [key, Constant.new(name: key.freeze, value: value, type: BASE_TYPES.fetch('u32')).freeze]
        end
      end

      def validate_architecture(by_kind)
        arches = by_kind.fetch('arch', [])
        if arches.empty?
          raise SchemaError, 'register/trap declarations require an architecture' if by_kind.key?('reg') || by_kind.key?('trap')
          return nil
        end
        raise SchemaError, 'duplicate architecture declaration' unless arches.size == 1
        arch = arches.first
        arity(arch.line, 2)
        no_members(arch)
        name = Syntax.identifier(arch.args.first, line: arch.line)
        arch.fail!('unsupported architecture binding') unless name == 'aarch64'
        arch.fail!('architecture file name does not match its declaration') unless arch.line.path == "abi/arch/#{name}.txt"
        registers = {}
        by_kind.fetch('reg', []).each do |declaration|
          arity(declaration.line, 3)
          no_members(declaration)
          role, values = declaration.args
          declaration.fail!('unknown or repeated register role') unless %w[number args results preserved].include?(role) && !registers.key?(role)
          registers[role] = list(values, declaration.line)
          unless registers.fetch(role).all? { |register| register.match?(/\Ax(?:[0-9]|[12][0-9]|30)\z/) }
            declaration.fail!('unknown architecture register')
          end
        end
        traps = by_kind.fetch('trap', [])
        raise SchemaError, 'exactly one architecture trap is required' unless traps.size == 1
        trap = traps.first
        if trap
          arity(trap.line, 3)
          no_members(trap)
          unsigned(trap.args[1], trap.line, maximum: 65535)
          trap.fail!('unsupported architecture trap opcode') unless trap.args[0] == 'svc'
        end
        unless registers.keys.sort == %w[args number preserved results] &&
               registers.fetch('number').size == 1 && registers.fetch('args').size == 6 &&
               registers.fetch('results').size == 3
          arch.fail!('architecture requires one number, six arguments and status plus two results')
        end
        unless (registers.fetch('preserved') & registers.fetch('results')).empty?
          arch.fail!('result register cannot be preserved')
        end
        number = registers.fetch('number').first
        arch.fail!('call number register overlaps arguments or results') if registers.fetch('args').include?(number) || registers.fetch('results').include?(number)
        expected_preserved = (0..30).map { |index| "x#{index}" } - registers.fetch('results')
        arch.fail!('preserved set omits a non-result register') unless registers.fetch('preserved').sort == expected_preserved.sort
        { name: name, registers: registers.freeze, trap: trap&.args&.freeze }.freeze
      end

      def validate_objects(declarations, rights)
        objects = {}
        declarations.each do |declaration|
          arity(declaration.line, 3)
          name, number = declaration.args
          sets = {}
          declaration.members.each do |line|
            arity(line, 2)
            key, value = line.words
            line.fail!('unknown or duplicate object rights set') unless %w[rights pass].include?(key) && !sets.key?(key)
            members = list(value, line)
            line.fail!('undefined right') unless (members - rights.keys).empty?
            sets[key] = members
          end
          declaration.fail!('object needs rights and pass sets') unless sets.keys.sort == %w[pass rights]
          declaration.fail!('pass set exceeds type rights') unless (sets.fetch('pass') - sets.fetch('rights')).empty?
          objects[name] = { number: positive(number, declaration.line, maximum: 65535), sets: sets.freeze }.freeze
        end
        if objects.any?
          unique_values(objects.transform_values { |object| object.fetch(:number) }, label: 'object type', line: declarations.first.line)
        end
        objects.sort.to_h
      end

      # A creation kind names one way an object is made and the rights its
      # capability is created with (docs/design-kernel.md, "Rights"). Each
      # kind's default lies within its type's carryable rights, and a kind
      # that carves another, as a carved budget carves the root budget's,
      # creates nothing its parent was not created with, DESTROY aside, so
      # a carve, a shrink of a create, never needs a right its parent lacks.
      def validate_kinds(declarations, objects, rights)
        kinds = {}
        declarations.each do |declaration|
          arity(declaration.line, 4)
          name, number, type = declaration.args
          object = objects[type] || declaration.fail!('undefined kind object type')
          sets = {}
          declaration.members.each do |line|
            arity(line, 2)
            key, value = line.words
            line.fail!('unknown or duplicate kind member') unless %w[default carves].include?(key) && !sets.key?(key)
            sets[key] = key == 'default' ? list(value, line) : Syntax.identifier(value, line: line)
          end
          default = sets['default'] || declaration.fail!('kind needs a default set')
          declaration.fail!('undefined right') unless (default - rights.keys).empty?
          declaration.fail!('kind default exceeds type rights') unless (default - object.fetch(:sets).fetch('rights')).empty?
          kinds[name] = { number: positive(number, declaration.line, maximum: 65535), type: type,
                          default: default, carves: sets['carves'], line: declaration.line }
        end
        kinds.each_value do |kind|
          next unless kind.fetch(:carves)

          parent = kinds[kind.fetch(:carves)] || kind.fetch(:line).fail!('undefined carved kind')
          kind.fetch(:line).fail!('carved kind of another type') unless parent.fetch(:type) == kind.fetch(:type)
          unless (kind.fetch(:default) - parent.fetch(:default) - %w[destroy]).empty?
            kind.fetch(:line).fail!('carved kind exceeds its parent kind and destroy')
          end
        end
        if kinds.any?
          unique_values(kinds.transform_values { |kind| kind.fetch(:number) }, label: 'creation kind', line: declarations.first.line)
        end
        kinds.sort.to_h.transform_values { |kind| kind.except(:line).freeze }
      end

      def validate_caps(declarations, objects, rights)
        caps = {}
        declarations.each do |declaration|
          arity(declaration.line, 5)
          no_members(declaration)
          name, slot, type, required = declaration.args
          object = objects[type] || declaration.fail!('undefined capability object type')
          selected = list(required, declaration.line)
          declaration.fail!('capability rights exceed its object type') unless (selected - object.fetch(:sets).fetch('rights')).empty?
          caps[name] = { slot: positive(slot, declaration.line, maximum: (1 << 24) - 1),
                         type: type, rights: selected.reduce(0) { |mask, right| mask | rights.fetch(right) } }.freeze
        end
        if caps.any?
          unique_values(caps.transform_values { |cap| cap.fetch(:slot) }, label: 'root slot', line: declarations.first.line)
        end
        caps.sort.to_h
      end

      # These declaration families are validated in their own bounded passes.
      # The representation/readers stay independent of syscall and service use.
      def validate_calls(declarations, types, constants, objects, rights)
        require_relative 'abi_contracts'
        Contracts.calls(declarations, types: types, constants: constants,
                        objects: objects, rights: rights)
      end

      def validate_reader(declaration, types, constants)
        require_relative 'abi_contracts'
        Contracts.reader(declaration, types: types, constants: constants)
      end

      def validate_translations(declarations, types)
        require_relative 'abi_contracts'
        Contracts.translations(declarations, types: types)
      end

      def validate_services(declarations)
        require_relative 'abi_contracts'
        Contracts.services(declarations)
      end

      def validate_projections(declarations, types)
        declarations.map do |declaration|
          arity(declaration.line, 4)
          name, layout_name, build = declaration.args
          layout = types[layout_name]
          declaration.fail!('projection needs a layout and release/development build') unless layout.is_a?(Layout) && %w[release development].include?(build)
          declaration.fail!('a private layout cannot be projected') if layout.private?
          leaves = leaf_fields(layout)
          selected = {}
          declaration.members.each do |line|
            arity(line, 2)
            operation, field_name = line.words
            field = leaves[field_name]
            line.fail!('invalid projection field') unless field && %w[show omit].include?(operation) && !selected.key?(field.name)
            if operation == 'show' && (!field.visibility || field.visibility == 'internal' || (build == 'release' && field.visibility == 'development'))
              line.fail!('projection exposes an unavailable field')
            end
            selected[field_name] = operation
          end
          declaration.fail!('projection does not classify every leaf field') unless selected.keys.sort == leaves.keys.sort
          { name: name, layout: layout_name, build: build, fields: selected.freeze }.freeze
        end.freeze
      end

      def leaf_fields(layout)
        pending = layout.fields.reverse.map { |field| ['', field] }
        leaves = {}
        until pending.empty?
          prefix, field = pending.pop
          name = prefix + field.name + (field.array? ? '[]' : '')
          if field.type.is_a?(Layout)
            field.type.fields.reverse_each { |child| pending << [name + '.', child] }
          else
            leaves[name] = field
          end
        end
        leaves.freeze
      end
    end
  end
end
