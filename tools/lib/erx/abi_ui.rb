# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # A property's type, resolved. FORM is one of integer, text, bytes, list,
    # enum, boolean, image, key, event and presentation. MINIMUM and MAXIMUM
    # bound an integer; MAXIMUM is a text's or bytes' byte count and a list's
    # entry count; ELEMENT is a list's text type; ATOMS are an enum's or the
    # image types' names in number order.
    UIType = Struct.new(:name, :form, :minimum, :maximum, :element, :atoms, keyword_init: true)
    UIImage = Struct.new(:name, :number, :content_type, keyword_init: true)
    # DEFAULT is the value the property's absence means, as an Integer, true,
    # false or an enum member's name, or nil. DETAIL is 'state' for an event
    # whose detail is the kind's state value.
    UIProperty = Struct.new(:name, :number, :type, :common, :status, :default, :detail, keyword_init: true)
    # One property a kind takes, with the marks of its line beneath the kind:
    # WITHIN is [LOW, HIGH], INDEX the list property, HIDES the hidden one.
    UITaken = Struct.new(:property, :state, :fixed, :within, :index, :hides, keyword_init: true)
    # TAKES holds every property the kind takes, the common ones first, in
    # declaration order.
    UIKind = Struct.new(:name, :number, :children, :takes, keyword_init: true) do
      def taken(name) = takes.find { |entry| entry.property.name == name }
      def state = takes.find(&:state)
    end
    UISchema = Struct.new(:version, :images, :properties, :kinds, :insert_max, :children_max, keyword_init: true)

    # The reader of the one `ui VERSION` declaration (docs/design-abi.md,
    # "Widget format"). It refuses every source the grammar refuses and
    # returns a frozen schema with every reference resolved.
    module UI
      SOURCE = 'abi/formats/ui.txt'
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/.freeze
      NUMBERS = 1..255
      INT32 = (-(1 << 31))..((1 << 31) - 1)
      MAX_BYTES = 65_536
      MAX_LIST = 1000
      KEY_MAX = 255
      # The forms a property's TYPE may name without declaring them.
      BUILTIN_TYPES = %w[boolean image key event presentation].freeze
      # The binary form's fixed sizes (docs/design-abi.md, "Widget format"):
      # an insert's tag, node, parent, index, kind and property count; a
      # status block of status, reporter, a stopgap name of at most 63 bytes
      # and a timeout; a presentation's name of at most 63 bytes and its
      # canonical text of at most 4,096 bytes.
      INSERT_HEADER = 1 + 4 + 4 + 2 + 1 + 1
      STATUS_BLOCK = 1 + 1 + 1 + 63 + 4
      PRESENTATION = 1 + 63 + 4 + 4096

      module_function

      # LIMITS are the root limits by name and TYPES the root types, of which
      # a property names a u8 enum by @name.
      def validate(declarations, limits:, types:)
        return nil if declarations.empty?

        declarations.drop(1).first&.fail!('exactly one ui declaration is allowed')
        declaration = declarations.first
        declaration.fail!("the ui declaration belongs in #{SOURCE}") unless declaration.line.path == SOURCE
        declaration.fail!('expected ui VERSION') unless declaration.line.tokens.size == 2
        version = Syntax.integer(declaration.args.first, line: declaration.line)
        declaration.fail!('ui version must be positive and fit 32 bits') unless version.between?(1, 0xffffffff)
        op_max = limits['web_ui_op_max'] || declaration.fail!('ui.txt needs the root limit web_ui_op_max')
        children_max = limits['ui_children'] || declaration.fail!('ui.txt needs the root limit ui_children')
        declaration.fail!('ui_children must lie in 1..65536, an index being a u16') unless children_max.between?(1, 65_536)
        Reader.new(declaration, types).schema(version, op_max: op_max, children_max: children_max)
      end

      # Validation state for one declaration: the members grouped with their
      # four-space lines, then each family resolved against the earlier ones.
      class Reader
        def initialize(declaration, root_types)
          @root_types = root_types
          @groups = declaration.members.each_with_object([]) do |line, groups|
            if line.indent == 2
              groups << [line, []]
            else
              line.fail!('a four-space line belongs under a kind') unless groups.last&.first&.words&.first == 'kind'
              groups.last.last << line
            end
          end
        end

        def schema(version, op_max:, children_max:)
          types = {}
          images = {}
          # Value types and image types share a namespace with the built-in types.
          type_names = BUILTIN_TYPES.to_h { |name| [name, :builtin] }
          properties = {}
          kinds = {}
          @groups.each do |line, _children|
            case line.words.first
            when 'integer', 'text', 'bytes', 'list' then types[declare_type(line, type_names)] = value_type(line, types)
            when 'image' then images[declare_type(line, type_names)] = image(line, images)
            when 'prop' then properties[declare(line, properties)] = property(line, types, images, properties)
            when 'kind' then nil
            else line.fail!("unknown ui member #{line.words.first}")
            end
          end
          @groups.each do |line, children|
            kinds[declare(line, kinds)] = kind(line, children, properties, kinds) if line.words.first == 'kind'
          end
          check_key(properties)
          insert_max = kinds.values.to_h { |kind| [kind.name, insert_size(kind)] }
          insert_max.each do |name, size|
            next if size <= op_max

            @groups.find { |line, _| line.words[0] == 'kind' && line.words[1] == name }.first
                   .fail!("kind #{name}'s largest insert, #{size} bytes, exceeds web_ui_op_max")
          end
          UISchema.new(version: version, images: images.values, properties: properties.values,
                       kinds: kinds.values, insert_max: insert_max, children_max: children_max)
        end

        private

        def declare(line, namespace)
          name = line.words[1]
          line.fail!("invalid ui name #{name.inspect}") unless name&.match?(NAME)
          line.fail!("duplicate ui name #{name}") if namespace.key?(name)
          name
        end

        def declare_type(line, type_names)
          name = declare(line, type_names)
          type_names[name] = true
          name
        end

        def number(word, line, used)
          value = Syntax.integer(word, line: line)
          line.fail!("number #{value} outside 1..255") unless NUMBERS.cover?(value)
          line.fail!("duplicate number #{value}") if used.any? { |item| item.number == value }
          value
        end

        def value_type(line, types)
          name = line.words[1]
          case line.words
          in ['integer', _, low, high]
            minimum = Syntax.integer(low, line: line)
            maximum = Syntax.integer(high, line: line)
            line.fail!('integer bounds must lie within 32 bits, low first') unless INT32.cover?(minimum) && INT32.cover?(maximum) && minimum <= maximum
            UIType.new(name: name, form: 'integer', minimum: minimum, maximum: maximum)
          in ['text', _, max, 'utf8']
            UIType.new(name: name, form: 'text', maximum: bound(max, MAX_BYTES, line))
          in ['bytes', _, max]
            UIType.new(name: name, form: 'bytes', maximum: bound(max, MAX_BYTES, line))
          in ['list', _, element, max]
            text = types[element]
            line.fail!("list element #{element} is not a text type") unless text&.form == 'text'
            UIType.new(name: name, form: 'list', element: text, maximum: bound(max, MAX_LIST, line))
          else line.fail!("malformed #{line.words.first} member")
          end
        end

        def bound(word, maximum, line)
          value = Syntax.integer(word, line: line)
          line.fail!("bound #{value} outside 0..#{maximum}") unless value.between?(0, maximum)
          value
        end

        def image(line, images)
          line.fail!('expected image NAME NUMBER "CONTENT_TYPE"') unless line.tokens.size == 4 && line.tokens[3].quoted
          content_type = line.words[3]
          unless content_type.match?(%r{\Aimage/[a-z0-9.+-]+\z}) && content_type != 'image/svg+xml'
            line.fail!("content type #{content_type} is not a raster image/ type")
          end
          UIImage.new(name: line.words[1], number: number(line.words[2], line, images.values), content_type: content_type)
        end

        def property(line, types, images, properties)
          name = line.words[1]
          num = number(line.words[2], line, properties.values)
          type = property_type(line.words[3], line, types, images)
          marks = line.words.drop(4)
          common = marks.delete('common')
          status = marks.delete('status')
          default = nil
          detail = nil
          until marks.empty?
            case marks
            in ['default', value, *rest]
              default = default_value(value, type, line)
              marks = rest
            in ['detail', 'state', *rest]
              line.fail!('only an event has a detail') unless type.form == 'event'
              detail = 'state'
              marks = rest
            else line.fail!("unknown property mark #{marks.first}")
            end
          end
          if status && !%w[text presentation].include?(type.form)
            line.fail!('only a text or presentation property carries a status')
          end
          if (type.form == 'key') != (name == 'key')
            line.fail!('the property key, and only it, has the type key')
          end
          UIProperty.new(name: name, number: num, type: type, common: !common.nil?, status: !status.nil?,
                         default: default, detail: detail)
        end

        def property_type(word, line, types, images)
          line.fail!('a property needs a type') unless word
          if word.start_with?('@')
            enum = @root_types[word.delete_prefix('@')]
            line.fail!("#{word} is not a root enum of type u8") unless enum.is_a?(EnumType) && !enum.flags && enum.base.size == 1 && !enum.base.signed
            return UIType.new(name: word, form: 'enum', atoms: enum.members.sort_by { |_, value| value }.map(&:first))
          end
          if word == 'image'
            line.fail!('an image property follows the image types it takes') if images.empty?
            return UIType.new(name: word, form: word, atoms: images.values.sort_by(&:number).map(&:name))
          end
          return UIType.new(name: word, form: word) if BUILTIN_TYPES.include?(word)

          types[word] || line.fail!("unknown ui type #{word}")
        end

        def default_value(word, type, line)
          case type.form
          when 'integer'
            value = Syntax.integer(word, line: line)
            line.fail!("default #{value} outside #{type.name}") unless value.between?(type.minimum, type.maximum)
            value
          when 'boolean'
            line.fail!('a boolean default is true or false') unless %w[true false].include?(word)
            word == 'true'
          when 'enum'
            line.fail!("default #{word} is not a member of #{type.name}") unless type.atoms.include?(word)
            word
          else line.fail!("a #{type.form} property has no default")
          end
        end

        def kind(line, children, properties, kinds)
          case line.words
          in ['kind', name, num] then takes_children = false
          in ['kind', name, num, 'children'] then takes_children = true
          else line.fail!('expected kind NAME NUMBER [children]')
          end
          number = number(num, line, kinds.values)
          common = properties.values.select(&:common).map { |property| UITaken.new(property: property) }
          listed = children.map { |child| taken(child, properties) }
          (common + listed).group_by { |entry| entry.property.name }.each do |prop, entries|
            line.fail!("kind #{name} takes #{prop} twice") if entries.size > 1
          end
          kind = UIKind.new(name: name, number: number, children: takes_children, takes: common + listed)
          check_marks(kind, line)
          kind
        end

        def taken(line, properties)
          line.fail!('expected prop NAME [marks]') unless line.words.first == 'prop'
          property = properties[line.words[1]] || line.fail!("unknown property #{line.words[1]}")
          line.fail!("#{property.name} is common to every kind") if property.common
          marks = line.words.drop(2)
          entry = { property: property }
          until marks.empty?
            case marks
            in ['state', *rest] then entry[:state] = true
            in ['fixed', *rest] then entry[:fixed] = true
            in ['within', low, high, *rest] then entry[:within] = [low, high]
            in ['index', list, *rest] then entry[:index] = list
            in ['hides', hidden, *rest] then entry[:hides] = hidden
            else line.fail!("unknown kind property mark #{marks.first}")
            end
            marks = rest
          end
          UITaken.new(**entry)
        end

        # The cross-property marks name properties the kind takes, of the
        # forms the validator compares; within's bounds have defaults, so a
        # tree that omits them still has a range.
        def check_marks(kind, line)
          states = kind.takes.count(&:state)
          line.fail!("kind #{kind.name} has #{states} state properties") if states > 1
          if kind.takes.any? { |entry| entry.property.detail == 'state' } && states != 1
            line.fail!("kind #{kind.name} takes a state event without one state property")
          end
          kind.takes.each do |entry|
            name = entry.property.name
            entry.within&.each do |bound|
              other = kind.taken(bound)&.property
              unless entry.property.type.form == 'integer' && other&.type&.form == 'integer' && !other.default.nil?
                line.fail!("#{name} within #{bound}: both integers, the bound taken with a default")
              end
            end
            if entry.within && kind.taken(entry.within[0]).property.default >= kind.taken(entry.within[1]).property.default
              line.fail!("#{name} within: the low bound's default must lie below the high bound's")
            end
            if entry.index
              list = kind.taken(entry.index)&.property
              unless entry.property.type.form == 'integer' && list&.type&.form == 'list'
                line.fail!("#{name} index #{entry.index}: an integer indexing a list the kind takes")
              end
            end
            next unless entry.hides

            unless entry.property.type.form == 'boolean' && entry.fixed && kind.taken(entry.hides)
              line.fail!("#{name} hides #{entry.hides}: a fixed boolean hiding a property the kind takes")
            end
          end
        end

        def check_key(properties)
          key = properties['key']
          @groups.first&.first&.fail!('ui.txt declares no common key property') unless key&.common
        end

        # The largest insert of KIND: its header and every property it takes
        # at its bound, the key excepted, which is never written.
        def insert_size(kind)
          INSERT_HEADER + kind.takes.sum do |entry|
            property = entry.property
            next 0 if property.type.form == 'key'

            1 + (property.status ? STATUS_BLOCK : 0) + value_size(property.type)
          end
        end

        def value_size(type)
          case type.form
          when 'boolean', 'enum', 'image' then 1
          when 'integer' then 4
          when 'text', 'bytes' then 4 + type.maximum
          when 'list' then 2 + (type.maximum * value_size(type.element))
          when 'event' then 0
          when 'presentation' then PRESENTATION
          end
        end
      end
    end
  end
end
