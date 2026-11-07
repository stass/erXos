# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # A value type of the inspection schema, resolved. FORM is one of
    # integer, text, atoms, flags, list, tuple, boolean and pid. NAME is the
    # member's name, or for a type the schema does not declare itself the
    # reference that names it: `boolean`, `pid`, `rights`, `object_type`,
    # `status` or `@root_name`. ELEMENT and ELEMENTS name other types by
    # such references, which key InspectionSchema#types.
    InspectionType = Struct.new(:name, :form, :minimum, :maximum, :multiple, :unit,
                                :utf8, :atoms, :element, :elements, :member, keyword_init: true)
    InspectionStopgap = Struct.new(:name, :category, :label, :scope, keyword_init: true)
    # A trace row (docs/design-live.md, "Tracing") and the one reporter, a
    # category or a stopgap name, that its collector assigns to its events.
    InspectionTraceRow = Struct.new(:name, :reporter, keyword_init: true)
    # REPORTERS holds category names and stopgap names, as the schema lists them.
    # DERIVED holds the keys of the attributes the inspector computes this one
    # from, and is empty for an attribute a report carries.
    InspectionAttribute = Struct.new(:key, :type, :reporters, :visible, :build,
                                     :projections, :derived, keyword_init: true)
    # A literal segment has LITERAL; a variable segment has TYPE.
    InspectionSegment = Struct.new(:literal, :type, keyword_init: true) do
      def variable? = literal.nil?
    end
    # VISIBILITY is the visibility marks of the path and of its prefixes,
    # outermost first. LITERAL_CHILDREN is the literal names that extend the
    # path by one, in declaration order, and VARIABLE_CHILD the type
    # reference of its one variable extension, or nil; ENTRIES is nil or
    # [type reference, maximum].
    InspectionPath = Struct.new(:kind, :segments, :entries, :append_only,
                                :visibility, :literal_children, :variable_child,
                                keyword_init: true)
    InspectionSchema = Struct.new(:version, :units, :types, :member_types, :stopgaps,
                                  :kinds, :paths, :trace_rows, keyword_init: true)

    # The reader of the one `inspection SCHEMA` declaration
    # (docs/design-abi.md, "Inspection schema"). It refuses every source the
    # grammar refuses and returns a frozen schema with every reference
    # resolved, so an emitter never meets an unchecked name.
    module Inspection
      SOURCE = 'abi/inspection.txt'
      CATEGORIES = %w[kernel service runtime].freeze
      VISIBILITY = %w[any owner all system_shell].freeze
      BUILDS = %w[all development].freeze
      PROJECTIONS = %w[shell host proc web].freeze
      BUILTIN_TYPES = %w[boolean pid rights object_type status].freeze
      VALUE_MEMBERS = %w[integer text atoms list tuple].freeze
      RESERVED = (CATEGORIES + BUILTIN_TYPES + %w[listing none]).freeze
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/.freeze
      MAX_DEPTH = 8
      MAX_LIST = 1000
      MAX_TUPLE = 16
      MAX_SEGMENTS = 16
      MAX_SEGMENT_TEXT = 256
      # Bounds the grammar leaves open, chosen here: a record is at most
      # 64 KiB (docs/design-live.md, "The /proc tree"), so no text exceeds
      # it; labels and scopes are one renderer line.
      MAX_TEXT = 65_536
      MAX_ENTRIES = 0xffffffff
      MAX_LABEL = 255
      MAX_SCOPE = 1024
      INTEGER_RANGE = (-(1 << 63))..((1 << 64) - 1)
      ATTRIBUTE_WORDS = %w[attr KEY TYPE reporters LIST visible CLASS build BUILD projections LIST].freeze
      DERIVED_WORDS = %w[derived INPUTS].freeze
      # The root enum of erx_object_info's topics; a topic named after a kind
      # reports it in the root layout erx_info_<kind>.
      TOPICS = 'info_kind'
      # Fields of a report layout that are not attribute fields: the mask
      # itself, and the object id that names a listed record.
      REPORTED = 'reported'
      RECORD_ID = 'id'

      module_function

      # DECLARATIONS are this source's `inspection` lines; ROOT gives the root
      # names a member may refer to: limits, types (scalar, enum and flags),
      # rights, objects and statuses.
      def validate(declarations, limits:, types:, rights:, objects:, statuses:)
        return nil if declarations.empty?

        declarations.drop(1).first&.fail!('exactly one inspection declaration is allowed')
        declaration = declarations.first
        declaration.fail!("the inspection declaration belongs in #{SOURCE}") unless declaration.line.path == SOURCE
        declaration.fail!('expected inspection SCHEMA') unless declaration.line.tokens.size == 2
        version = Syntax.integer(declaration.args.first, line: declaration.line)
        declaration.fail!('inspection schema number must be positive and fit 32 bits') unless version.between?(1, 0xffffffff)
        root = { limits: limits, types: types, rights: rights, objects: objects, statuses: statuses }
        Reader.new(declaration, root).schema(version)
      end

      # Validation state for one declaration: members grouped with their
      # four-space lines, then each family checked against the others.
      class Reader
        def initialize(declaration, root)
          @declaration = declaration
          @root = root
          @groups = group(declaration.members)
          @names = {}
        end

        def schema(version)
          units = {}
          stopgaps = {}
          values = {}
          kind_lines = {}
          paths = []
          rows = []
          @groups.each do |line, children|
            case line.words.first
            when 'unit' then units[declare(line)] = unit(line, children)
            when *VALUE_MEMBERS then values[declare(line)] = [line, children]
            when 'stopgap' then stopgaps[declare(line)] = stopgap(line, children)
            when 'kind' then kind_lines[declare(line)] = [line, children]
            when 'path' then paths << [line, children]
            when 'trace' then rows << [line, children]
            else line.fail!("unknown inspection member #{line.words.first}")
            end
          end
          check_stopgap_labels(stopgaps)
          types = resolve_values(values, units)
          kinds = kind_lines.to_h { |name, (line, children)| [name, attributes(line, children, types, stopgaps)] }
          check_reports(kinds)
          paths = resolve_paths(paths, kinds, types)
          trace_rows = trace_rows(rows, stopgaps)
          check_used(units, values, stopgaps, kinds, types, paths, trace_rows)
          InspectionSchema.new(version: version, units: units, types: types,
                               member_types: values.keys, stopgaps: stopgaps,
                               kinds: kinds, paths: paths, trace_rows: trace_rows)
        end

        private

        def group(members)
          members.each_with_object([]) do |line, groups|
            if line.indent == 2
              groups << [line, []]
            else
              line.fail!('a four-space line belongs under an inspection member') if groups.empty?
              groups.last.last << line
            end
          end
        end

        def declare(line)
          name = plain(line.words[1], line)
          line.fail!("#{name} is reserved in the inspection schema") if RESERVED.include?(name)
          line.fail!("duplicate inspection member #{name}") if @names.key?(name)
          @names[name] = line.words.first
          name
        end

        def plain(value, line)
          line.fail!("invalid inspection name #{value.inspect}") unless value&.match?(NAME)
          value
        end

        # Only labels and scopes are quoted, and they always are.
        def tokens(line, count, quoted: [])
          line.fail!("expected #{count - 1} fields for #{line.words.first}") unless line.tokens.size == count
          line.tokens.each_with_index do |token, index|
            line.fail!(quoted.include?(index) ? 'expected a quoted string' : 'quoted token is not permitted here') unless token.quoted == quoted.include?(index)
          end
          line.words
        end

        def unquoted(line)
          line.fail!('quoted token is not permitted here') if line.tokens.any?(&:quoted)
          line.words
        end

        def no_children(line, children)
          children.first&.fail!("#{line.words.first} takes no four-space members")
        end

        def printable(text, line, maximum:)
          unless !text.empty? && text.bytesize <= maximum && text.bytes.all? { |byte| byte.between?(32, 126) }
            line.fail!("a label or scope is 1 to #{maximum} bytes of printable ASCII")
          end
          text
        end

        def unit(line, children)
          no_children(line, children)
          printable(tokens(line, 3, quoted: [2])[2], line, maximum: MAX_LABEL)
        end

        def stopgap(line, children)
          no_children(line, children)
          _keyword, name, category, label, scope = tokens(line, 5, quoted: [3, 4])
          line.fail!("a stopgap stands in for kernel, service or runtime, not #{category}") unless CATEGORIES.include?(category)
          InspectionStopgap.new(name: name, category: category,
                                label: printable(label, line, maximum: MAX_LABEL),
                                scope: printable(scope, line, maximum: MAX_SCOPE))
        end

        def check_stopgap_labels(stopgaps)
          stopgaps.values.group_by(&:label).each do |label, group|
            line = line_of(group.last.name)
            line.fail!("stopgap label #{label.inspect} is a category's name") if CATEGORIES.include?(label)
            line.fail!("stopgap label #{label.inspect} is another stopgap's") if group.size > 1
          end
        end

        # A trace row's name is its own namespace, not a member's, since the
        # kernel's row shares the category's name. Its reporter is a category
        # or a stopgap; a row has exactly one, since a row's collector is one.
        def trace_rows(rows, stopgaps)
          rows.each_with_object({}) do |(line, children), result|
            no_children(line, children)
            _keyword, name, reporter = unquoted(line)
            line.fail!('expected trace ROW REPORTER') unless line.words.size == 3
            plain(name, line)
            line.fail!("duplicate trace row #{name}") if result.key?(name)
            line.fail!("undefined reporter #{reporter}") unless CATEGORIES.include?(reporter) || stopgaps.key?(reporter)
            result[name] = InspectionTraceRow.new(name: name, reporter: reporter)
          end
        end

        # The line that declares member NAME; paths and trace rows declare nothing.
        def line_of(name)
          @groups.find { |line, _children| !%w[path trace].include?(line.words.first) && line.words[1] == name }.first
        end

        # Member value types first, then every reference they make; a cycle
        # or a type nested more than eight deep fails.
        def resolve_values(values, units)
          types = {}
          values.each do |name, (line, children)|
            no_children(line, children)
            types[name] = value_type(name, line, units)
          end
          types.values.flat_map { |type| [type.element, *type.elements].compact }
               .each { |reference| types[reference] ||= reference_type(reference, line_of_type(types, reference)) }
          depths = {}
          types.each_key { |name| depth(name, types, [], depths) }
          types
        end

        def line_of_type(types, reference)
          user = types.values.find { |type| type.member && [type.element, *type.elements].include?(reference) }
          line_of(user.name)
        end

        def value_type(name, line, units)
          words = unquoted(line)
          case words.first
          when 'integer'
            unit_name = nil
            if words.size == 6
              line.fail!('expected unit UNIT after the bounds') unless words[4] == 'unit'
              unit_name = words[5]
              line.fail!("undefined unit #{unit_name}") unless units.key?(unit_name)
            elsif words.size != 4
              line.fail!('expected integer NAME MIN MAX [unit UNIT]')
            end
            minimum, maximum = words[2, 2].map { |word| bound(word, line) }
            line.fail!('integer minimum exceeds its maximum') if minimum > maximum
            InspectionType.new(name: name, form: 'integer', minimum: minimum, maximum: maximum,
                               multiple: 1, unit: unit_name, member: true)
          when 'text'
            utf8 = words[3]
            line.fail!('expected text NAME MAX [utf8]') unless [3, 4].include?(words.size) && [nil, 'utf8'].include?(utf8)
            InspectionType.new(name: name, form: 'text', maximum: count(words[2], line, MAX_TEXT),
                               utf8: !utf8.nil?, member: true)
          when 'atoms'
            atoms = words.drop(2)
            line.fail!('expected atoms NAME ATOM...') if atoms.empty?
            atoms.each { |atom| plain(atom, line) }
            line.fail!('duplicate atom in a closed set') unless atoms.uniq.size == atoms.size
            InspectionType.new(name: name, form: 'atoms', atoms: atoms, member: true)
          when 'list'
            line.fail!('expected list NAME TYPE MAX') unless words.size == 4
            InspectionType.new(name: name, form: 'list', element: reference(words[2], line),
                               maximum: count(words[3], line, MAX_LIST), member: true)
          when 'tuple'
            elements = words.drop(2)
            line.fail!("a tuple holds 2 to #{MAX_TUPLE} values") unless elements.size.between?(2, MAX_TUPLE)
            InspectionType.new(name: name, form: 'tuple', elements: elements.map { |item| reference(item, line) },
                               member: true)
          end
        end

        def bound(word, line)
          value = if word&.start_with?('@')
                    @root.fetch(:limits)[word.delete_prefix('@')] || line.fail!("#{word} is not a root limit")
                  else
                    Syntax.integer(word, line: line)
                  end
          line.fail!('integer bound is outside the 64-bit range') unless INTEGER_RANGE.cover?(value)
          value
        end

        def count(word, line, maximum)
          value = Syntax.integer(word, line: line)
          line.fail!("bound must be 1 to #{maximum}") unless value.between?(1, maximum)
          value
        end

        # A type reference as written: a member name, a built-in or @root.
        def reference(word, line)
          return word if BUILTIN_TYPES.include?(word) || word.start_with?('@')
          return word if @names[word] && VALUE_MEMBERS.include?(@names[word])

          line.fail!("undefined inspection type #{word}")
        end

        def reference_type(reference, line)
          case reference
          when 'boolean', 'pid' then InspectionType.new(name: reference, form: reference, member: false)
          when 'rights' then atoms_type(reference, 'flags', @root.fetch(:rights))
          when 'object_type' then atoms_type(reference, 'atoms', @root.fetch(:objects))
          when 'status' then atoms_type(reference, 'atoms', @root.fetch(:statuses))
          else root_type(reference, line)
          end
        end

        def atoms_type(name, form, atoms)
          InspectionType.new(name: name, form: form, atoms: atoms.sort, member: false)
        end

        def root_type(reference, line)
          type = @root.fetch(:types)[reference.delete_prefix('@')]
          case type
          when ScalarType
            InspectionType.new(name: reference, form: 'integer', minimum: type.minimum, maximum: type.maximum,
                               multiple: type.multiple, member: false)
          when EnumType
            atoms_type(reference, type.flags ? 'flags' : 'atoms', type.members.keys)
          else
            line.fail!("#{reference} is not a root scalar, enum or flags")
          end
        end

        # The nesting depth of type NAME, each type's computed once into DEPTHS.
        def depth(name, types, trail, depths)
          return depths.fetch(name) if depths.key?(name)

          line_of(trail.first || name).fail!("type #{name} refers to itself") if trail.include?(name)
          type = types.fetch(name)
          inner = [type.element, *type.elements].compact.map { |item| depth(item, types, trail + [name], depths) }.max || 0
          total = 1 + inner
          line_of(trail.first || name).fail!("type #{name} is nested more than #{MAX_DEPTH} deep") if total > MAX_DEPTH
          depths[name] = total
        end

        def attributes(line, children, types, stopgaps)
          unquoted(line)
          line.fail!('expected kind NAME') unless line.words.size == 2
          keys = {}
          attrs = children.map do |child|
            attribute(child, types, stopgaps).tap do |attr|
              child.fail!("duplicate attribute #{attr.key}") if keys.key?(attr.key)
              keys[attr.key] = attr
            end
          end
          children.zip(attrs).each { |child, attr| check_inputs(child, attr, keys) }
          attrs
        end

        # A derived attribute is computed from attributes a report or another
        # source carries, never from another derived one, so one pass over
        # the kind's record computes every derived value.
        def check_inputs(line, attr, keys)
          attr.derived.each do |input|
            source = keys[input] || line.fail!("derived input #{input} is no attribute of the kind")
            line.fail!("derived input #{input} is itself derived") unless source.derived.empty?
          end
        end

        def attribute(line, types, stopgaps)
          words = unquoted(line)
          keywords = [0, 3, 5, 7, 9]
          optional = words.drop(ATTRIBUTE_WORDS.size)
          derived_tail = optional.empty? || (optional.size == DERIVED_WORDS.size && optional.first == DERIVED_WORDS.first)
          unless words.size >= ATTRIBUTE_WORDS.size && words.values_at(*keywords) == ATTRIBUTE_WORDS.values_at(*keywords) && derived_tail
            line.fail!("expected #{ATTRIBUTE_WORDS.join(' ')} [#{DERIVED_WORDS.join(' ')}]")
          end
          key = plain(words[1], line)
          type = reference(words[2], line)
          types[type] ||= reference_type(type, line)
          InspectionAttribute.new(key: key, type: type, reporters: reporters(words[4], line, stopgaps),
                                  visible: choice(words[6], VISIBILITY, 'visibility', line),
                                  build: choice(words[8], BUILDS, 'build', line),
                                  projections: projections(words[10], line),
                                  derived: optional.empty? ? [] : names(optional.last, line))
        end

        def choice(word, allowed, label, line)
          allowed.include?(word) ? word : line.fail!("unknown #{label} #{word}")
        end

        def names(text, line)
          values = text.split(',', -1)
          line.fail!('duplicate or empty list member') unless values.none?(&:empty?) && values.uniq.size == values.size
          values
        end

        # A stopgap is listed beside the category it stands in for, so the
        # attribute stays declared for that category when the stopgap goes.
        # At most one stopgap stands in for each category, so a collector that
        # learns a value is partial knows whose count it is.
        def reporters(text, line, stopgaps)
          listed = names(text, line)
          gaps = listed.reject { |name| CATEGORIES.include?(name) }
                       .map { |name| stopgaps[name] || line.fail!("undefined reporter #{name}") }
          gaps.each do |stopgap|
            line.fail!("stopgap #{stopgap.name} is listed without its category #{stopgap.category}") unless listed.include?(stopgap.category)
          end
          gaps.group_by(&:category).each do |category, group|
            line.fail!("stopgaps #{group.map(&:name).join(' and ')} both stand in for #{category}") if group.size > 1
          end
          listed
        end

        def projections(text, line)
          return [] if text == 'none'

          names(text, line).each { |name| choice(name, PROJECTIONS, 'projection', line) }
        end

        def resolve_paths(entries, kinds, types)
          declared = entries.map { |line, children| path(line, children, kinds, types) }
          shapes = {}
          declared.each do |line, item|
            shape = item.segments.map { |segment| segment.literal || :variable }
            line.fail!('path is declared twice') if shapes.key?(shape)
            shapes[shape] = [line, item]
          end
          declared.each do |line, item|
            check_prefixes(line, item, shapes)
            check_extension(line, item, shapes)
          end
          declared.map { |_line, item| complete(item, shapes) }
        end

        def path(line, children, kinds, types)
          words = unquoted(line)
          kind = words[1]
          line.fail!("undefined kind #{kind.inspect}") unless kind == 'listing' || kinds.key?(kind)
          segments = words.drop(2).map { |word| segment(word, line, types) }
          line.fail!("a path has at most #{MAX_SEGMENTS} segments") if segments.size > MAX_SEGMENTS
          marks = path_marks(children, types)
          [line, InspectionPath.new(kind: kind, segments: segments, entries: marks[:entries],
                                    append_only: marks[:append_only], visibility: marks[:visible])]
        end

        def segment(word, line, types)
          return InspectionSegment.new(literal: plain(word, line)) unless word.start_with?('*')

          name = word.delete_prefix('*')
          type = name == 'pid' ? 'pid' : reference(name, line)
          types[type] ||= reference_type(type, line)
          resolved = types.fetch(type)
          unless resolved.form == 'pid' || (resolved.member && resolved.form == 'integer') ||
                 (resolved.member && resolved.form == 'text' && resolved.maximum <= MAX_SEGMENT_TEXT)
            line.fail!("a variable segment is an integer, a text of at most #{MAX_SEGMENT_TEXT} bytes or a pid")
          end
          InspectionSegment.new(type: type)
        end

        def path_marks(children, types)
          marks = {}
          children.each do |line|
            words = unquoted(line)
            mark = words.first
            line.fail!("duplicate path mark #{mark}") if marks.key?(mark.to_sym)
            case mark
            when 'entries'
              line.fail!('expected entries TYPE MAX') unless words.size == 3
              type = reference(words[1], line)
              types[type] ||= reference_type(type, line)
              marks[:entries] = [type, count(words[2], line, MAX_ENTRIES)]
            when 'append_only'
              line.fail!('append_only takes no fields') unless words.size == 1
              marks[:append_only] = true
            when 'visible'
              line.fail!('expected visible CLASS') unless words.size == 2
              marks[:visible] = choice(words[1], VISIBILITY, 'visibility', line)
            else
              line.fail!("unknown path mark #{mark}")
            end
          end
          children.first.fail!('append_only marks a path with entries') if marks[:append_only] && !marks[:entries]
          marks
        end

        def shape_of(segments)
          segments.map { |segment| segment.literal || :variable }
        end

        def check_prefixes(line, item, shapes)
          (0...item.segments.size).each do |length|
            prefix = shapes[shape_of(item.segments.take(length))]
            line.fail!('a proper prefix of this path is not declared') unless prefix
            prefix.last.segments.zip(item.segments).each do |theirs, ours|
              line.fail!('a variable segment differs in type from its prefix') unless theirs.type == ours.type
            end
          end
        end

        def check_extension(line, item, shapes)
          extensions = children_of(item, shapes)
          variables = extensions.count(&:variable?)
          line.fail!('a path is extended by literal segments or by one variable segment, never both') if variables.positive? && extensions.size > 1
        end

        def children_of(item, shapes)
          shapes.values.map(&:last).select do |other|
            other.segments.size == item.segments.size + 1 &&
              shape_of(other.segments.take(item.segments.size)) == shape_of(item.segments)
          end.map { |other| other.segments.last }
        end

        def complete(item, shapes)
          children = children_of(item, shapes)
          visibility = (0..item.segments.size).filter_map do |length|
            shapes.fetch(shape_of(item.segments.take(length))).last.visibility
          end.uniq
          item.dup.tap do |result|
            result.visibility = visibility
            result.append_only = item.append_only || false
            result.literal_children = children.reject(&:variable?).map(&:literal)
            result.variable_child = children.find(&:variable?)&.type
          end
        end

        # Each report layout's names against its kind (docs/design-abi.md,
        # "Kernel reports"), so the collector maps fields and reported bits to
        # attributes by name and keeps no table of its own. A topic named
        # after a kind must have the layout; a kind no topic reports needs none.
        def check_reports(kinds)
          types = @root.fetch(:types)
          topics = types[TOPICS]
          reports = types.keys.grep(/\Aerx_info_/)
          if !reports.empty? && !(topics.is_a?(EnumType) && !topics.flags)
            @declaration.fail!("report layouts #{reports.join(', ')} need the topic enum #{TOPICS}")
          end
          kinds.each do |kind, attrs|
            name = "erx_info_#{kind}"
            layout = types[name]
            if layout
              check_report(kind, name, layout, attrs)
            elsif topics.is_a?(EnumType) && topics.members.key?(kind)
              line_of(kind).fail!("topic #{kind} has no report layout #{name}")
            end
          end
        end

        # Every field but REPORTED and RECORD_ID names an attribute of the kind
        # that lists kernel and is not derived.
        def check_report(kind, name, layout, attrs)
          line_of(kind).fail!("#{name} is not a layout") unless layout.is_a?(Layout)
          layout.tail&.line&.fail!("report layout #{name} has no tail")
          reported = layout.fields.find { |field| field.name == REPORTED } || layout.line.fail!("#{name} has no #{REPORTED} field")
          attribute_fields = layout.fields.reject { |field| [REPORTED, RECORD_ID].include?(field.name) }
          attribute_fields.each do |field|
            attr = attrs.find { |item| item.key == field.name && item.reporters.include?('kernel') } ||
                   field.line.fail!("#{name} field #{field.name} names no attribute of its kind that lists kernel")
            field.line.fail!("#{name} field #{field.name} is a derived attribute") unless attr.derived.empty?
          end
          check_mask(name, reported, attribute_fields.map(&:name))
        end

        # REPORTED is a flags field whose bits are exactly the attribute fields' names.
        def check_mask(name, reported, fields)
          unless reported.type.is_a?(EnumType) && reported.type.flags && !reported.array?
            reported.line.fail!("#{REPORTED} of #{name} is not a flags field")
          end
          bits = reported.type.members.keys
          stray = bits - fields
          reported.line.fail!("#{REPORTED} bit #{stray.first} of #{name} names no attribute field") unless stray.empty?
          unmarked = fields - bits
          reported.line.fail!("#{name} field #{unmarked.first} has no #{REPORTED} bit") unless unmarked.empty?
        end

        def check_used(units, values, stopgaps, kinds, types, paths, trace_rows)
          used_units = types.values.filter_map(&:unit)
          units.each_key { |name| line_of(name).fail!("unit #{name} is not used") unless used_units.include?(name) }
          used_types = types.values.flat_map { |type| [type.element, *type.elements].compact } +
                       kinds.values.flatten.map(&:type) +
                       paths.flat_map { |item| item.segments.filter_map(&:type) + [item.entries&.first].compact }
          values.each_key { |name| line_of(name).fail!("type #{name} is not used") unless used_types.include?(name) }
          used_kinds = paths.map(&:kind)
          kinds.each_key { |name| line_of(name).fail!("kind #{name} has no path") unless used_kinds.include?(name) }
          listed = kinds.values.flatten.flat_map(&:reporters) + trace_rows.values.map(&:reporter)
          stopgaps.each_key { |name| line_of(name).fail!("stopgap #{name} reports no attribute or trace row") unless listed.include?(name) }
        end
      end
    end
  end
end
