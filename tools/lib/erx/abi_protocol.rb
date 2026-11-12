# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_profile'

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
MAX_CASES = 32
# Built-in kinds of a frame protocol: true or false, and a signal's protocol
# name from abi/signals.txt (docs/design-abi.md, "Program protocol").
FRAME_BUILTINS = %w[boolean signal].freeze
# The words after an integer's base that start an option, which end a list of values.
INTEGER_OPTIONS = %w[max in values or except unique refers local].freeze
# A list of a frame protocol may hold up to 2^24 elements; a frame's own bound holds it far below.
LIST_MAX = 1 << 24
      # The kind by which a request names a node. Each request field of this kind
      # ends in one of FID_ATTRIBUTES, what its fid names: "directory" a directory,
      # "node" any node, "new" a fid the request makes name a node (walk's may be
      # its own fid). No other field takes an attribute, so an operation cannot
      # leave a directory fid unchecked by omission.
      FID_KIND = 'fid'
      FID_ATTRIBUTES = %w[directory node new].freeze
      MAX_ERRORS = 64
      # An error reply is a reply of no operation, and the codec carries a reply as
      # {reply, Operation, Reply}, so neither word may name an operation.
      RESERVED_OPERATIONS = %w[error reply].freeze
      # The limit (abi/kernel.txt) naming the null capability, which a
      # capability kind excludes.
      CAP_NULL = 'cap_null'
      LENGTHS = { 'u16' => 65_535, 'u32' => 65_536 }.freeze
      # Names become Erlang atoms and functions: no reserved word, no dot, and no
      # kind whose check would clash with a BIF or a helper of the generated module.
      ERLANG_RESERVED = %w[after and andalso band begin bnot bor bsl bsr bxor case catch cond div else end
                           fun if let maybe not of or orelse receive rem try when xor].freeze
      RESERVED_KINDS = %w[atom binary bitstring boolean float function integer list list_of map number
                          pid port record reference signal tuple utf8].freeze

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

      # A protocol is one of two shapes: the file protocol's operations, each a
      # request and its reply with an errors list, or a channel's frames, each
      # {Tag, Version, Value} or {Tag, Version, Slot, Value} (docs/design-abi.md,
      # "Program protocol"). Both declare their kinds in the one language below;
      # the members that describe 9P2000.L's bytes fail in a frame protocol.
      def protocol(declaration, name, constants)
        errors = nil
        error_type = nil
        kinds = {}
        operations = []
        frames = []
        totals = {}
        version = nil
        reader = nil
        declaration.members.slice_before { |member| member.indent == 2 }.each do |line, *children|
          line.fail!('nested member has no parent') unless line.indent == 2
          keyword, *words = line.words
          case keyword
          when 'errors'
            line.fail!('duplicate errors list') if errors
            line.fail!('expected errors type N') unless words.size == 2 && words.first == 'type'
            error_type = number(words[1], 255, line, constants).fetch(:value)
            errors = error_numbers(children, line, constants)
          when 'integer', 'capability', 'text', 'tuple', 'list', 'map', 'union'
            kind_name = atom_name(words.first, line: line)
            line.fail!("reserved kind name #{kind_name}") if RESERVED_KINDS.include?(kind_name)
            if kinds.key?(kind_name) || BASE_KINDS.include?(kind_name) || totals.key?(kind_name)
              line.fail!("duplicate kind #{kind_name}")
            end
            line.fail!('only a map or a union takes members') unless children.empty? || %w[map union].include?(keyword)
            kinds[kind_name] = kind(keyword, words.drop(1), children, line, kinds, constants)
          when 'total'
            line.fail!('expected total NAME MAX') unless words.size == 2
            total = atom_name(words[0], line: line)
            line.fail!("duplicate total #{total}") if totals.key?(total) || kinds.key?(total)
            totals[total] = number(words[1], (1 << 32) - 1, line, constants)
          when 'version'
            line.fail!('expected one version N') unless words.size == 1 && version.nil?
            version = number(words[0], 255, line, constants).fetch(:value)
          when 'reader'
            line.fail!('expected one reader c') unless words == ['c'] && reader.nil?
            reader = 'c'
          when 'frame' then frames << frame(line, words, kinds)
          when 'operation'
            operations << operation(line, words, children, kinds, constants)
          else
            line.fail!("unknown protocol member #{keyword}")
          end
        end
        return Profile.frames(declaration, name: name, kinds: kinds, frames: frames, totals: totals,
                                           version: version, reader: reader, constants: constants,
                                           nine_p: errors || !operations.empty?) unless frames.empty?

        declaration.fail!('only a frame protocol takes version, reader or total') if version || reader || !totals.empty?
        Profile.operation_kinds!(declaration, kinds)
        declaration.fail!('protocol requires an errors list') unless errors
        declaration.fail!('protocol requires an operation') if operations.empty?
        Model.unique_values(operations.to_h { |item| [item.fetch(:name), item.fetch(:type)] },
                            label: 'operation type', line: declaration.line)
        unless operations.map { |item| item.fetch(:name) }.uniq.size == operations.size
          declaration.fail!('duplicate operation')
        end
        message_types = operations.flat_map { |item| [item.fetch(:type), item.fetch(:type) + 1] } + [error_type]
        declaration.fail!('message types of requests, replies and errors collide') unless message_types.uniq.size == message_types.size
        used = used_kinds(kinds, operations.flat_map { |item| item.fetch(:request) + (item.fetch(:reply) || []) }.map(&:last))
        unused = kinds.keys - used
        declaration.fail!("unused kinds #{unused.join(' ')}") unless unused.empty?
        { name: name, module: "#{name}_grammar", source: declaration.line.path,
          errors: errors.map(&:first).freeze, error_numbers: errors, error_type: error_type,
          kinds: kinds.freeze,
          operations: operations.freeze }.freeze
      end

      def kind(form, words, children, line, kinds, constants)
        case form
        when 'integer' then integer_kind(words, line, constants)
        when 'capability' then capability_kind(words, line, constants)
        when 'text' then text_kind(words, line, constants)
        when 'tuple'
          line.fail!('a tuple has 1 to 32 elements') unless words.size.between?(1, MAX_FIELDS)
          { form: 'tuple', elements: words.map { |word| known_kind(word, line, kinds) }.freeze }.freeze
        when 'list' then list_kind(words, line, kinds, constants)
        when 'map' then map_kind(words, children, line, kinds)
        when 'union' then union_kind(words, children, line, kinds)
        end
      end

      def map_kind(words, children, line, kinds)
        line.fail!('a map takes no options') unless words.empty?
        line.fail!('a map has 1 to 32 fields') unless children.size.between?(1, MAX_FIELDS)
        fields = children.map do |child|
          unless child.words.size == 3 && %w[field optional].include?(child.words.first)
            child.fail!('expected field NAME KIND or optional NAME KIND')
          end
          [atom_name(child.words[1], line: child), known_kind(child.words[2], child, kinds),
           child.words.first == 'optional'].freeze
        end
        line.fail!('duplicate map field') unless fields.map(&:first).uniq.size == fields.size
        # fields keeps the [name, kind] pairs every map has; optional names the keys that may be absent.
        { form: 'map', fields: fields.map { |field, kind, _| [field, kind].freeze }.freeze,
          optional: fields.select(&:last).map(&:first).freeze }.freeze
      end

      # Each "case ATOM [=ATOM...] [KIND...]": the atoms that select it, the
      # case's own first, and the kinds of its fields.
      def union_kind(words, children, line, kinds)
        line.fail!('a union takes no options') unless words.empty?
        line.fail!("a union has at most #{MAX_CASES} cases") if children.size > MAX_CASES
        cases = children.map do |child|
          keyword, first, *rest = child.words
          child.fail!('expected case ATOM [=ATOM...] [KIND...]') unless keyword == 'case' && first
          literals = rest.take_while { |word| word.start_with?('=') }
          fields = rest.drop(literals.size)
          child.fail!('a literal atom comes before the fields') if fields.any? { |word| word.start_with?('=') }
          atoms = [first, *literals.map { |word| word.delete_prefix('=') }].map { |word| atom_name(word, line: child) }
          child.fail!('a case has at most 32 elements') if atoms.size + fields.size > MAX_FIELDS
          { atoms: atoms.freeze, fields: fields.map { |word| known_kind(word, child, kinds) }.freeze,
            c_name: atoms.join('_') }.freeze
        end
        { form: 'union', cases: cases.freeze }.freeze
      end

      # u8, u16, u32 or u64, then the options: one of "max N", "in MIN MAX",
      # "values N..." and "or ATOM"; "except N", "unique", "refers LIST"
      # and "local", each at most once.
      def integer_kind(words, line, constants)
        base, *options = words
        line.fail!('an integer is u8, u16, u32 or u64') unless INTEGER_BITS.key?(base)
        maximum = (1 << INTEGER_BITS.fetch(base)) - 1
        value = ->(word) { number(word, maximum, line, constants) }
        result = { form: 'integer', base: base, local: false }
        until options.empty?
          option = options.shift
          range = %i[max min values atom].any? { |key| result.key?(key) }
          case option
          when 'max', 'in', 'values', 'or' then line.fail!('an integer takes one range') if range
          end
          line.fail!("duplicate integer option #{option}") if %w[except unique refers local].include?(option) &&
                                                             result.key?(option.to_sym) && result[option.to_sym]
          case option
          when 'max' then result[:max] = value.call(options.shift)
          when 'in'
            result[:min] = value.call(options.shift)
            result[:max] = value.call(options.shift)
            line.fail!('an integer range has MIN above MAX') if result[:min].fetch(:value) > result[:max].fetch(:value)
          when 'values'
            numbers = options.take_while { |word| !INTEGER_OPTIONS.include?(word) }
            line.fail!('values takes 1 to 16 numbers') unless numbers.size.between?(1, 16)
            options = options.drop(numbers.size)
            result[:values] = numbers.map(&value).freeze
            line.fail!('duplicate value') unless result[:values].map { |item| item.fetch(:value) }.uniq.size == numbers.size
          when 'or' then result[:atom] = atom_name(options.shift, line: line)
          when 'except' then result[:except] = value.call(options.shift)
          when 'unique' then result[:unique] = true
          when 'refers' then result[:refers] = atom_name(options.shift, line: line)
          when 'local' then result[:local] = true
          else line.fail!('an integer takes max N, in MIN MAX, values N..., or ATOM, except N, unique, refers LIST or local')
          end
        end
        line.fail!('only an integer with or ATOM may be local') if result[:local] && !result[:atom]
        if result.dig(:except, :constant) == CAP_NULL
          line.fail!('an integer excepting cap_null is a capability: declare it capability NAME')
        end
        result.freeze
      end

      # "capability NAME": a capability handle (docs/design-abi.md, "Program
      # protocol"). It reads as a u64 other than cap_null; it is unique, so
      # no two capabilities of one frame are equal; and capability: true is
      # what the profile's walk reads. A frame protocol takes no other u64
      # (Profile.u64_rule!), so a handle has no other spelling there.
      def capability_kind(words, line, constants)
        line.fail!('a capability takes no options') unless words.empty?
        line.fail!("a capability needs the limit #{CAP_NULL}") unless constants.key?(CAP_NULL)
        { form: 'integer', base: 'u64'.b, local: false,
          except: number("@#{CAP_NULL}", (1 << 64) - 1, line, constants),
          unique: true, capability: true }.freeze
      end

      # max N, then "utf8", "refuse" and its refusals, "assign", "path",
      # "sum TOTAL" and "length u16|u32", in any order.
      def text_kind(words, line, constants)
        line.fail!('a text starts with max N') unless words[0] == 'max' && words.size >= 2
        options = words.drop(2)
        result = { form: 'text', utf8: false, refuse: [], length: 'u16', assign: false, path: false }
        until options.empty?
          option = options.shift
          case option
          when 'utf8', 'assign', 'path'
            line.fail!("duplicate text option #{option}") if result[option.to_sym]
            result[option.to_sym] = true
          when 'refuse'
            refusals = options.take_while { |word| REFUSALS.include?(word) }
            line.fail!('expected refuse followed by refusals') if refusals.empty? || !result[:refuse].empty?
            line.fail!('unknown or duplicate refusal') unless refusals.uniq.size == refusals.size
            options = options.drop(refusals.size)
            result[:refuse] = refusals
          when 'sum' then result[:sum] = atom_name(options.shift, line: line)
          when 'length'
            result[:length] = options.shift
            result[:length_given] = true
            line.fail!('a text has length u16 or u32') unless LENGTHS.key?(result[:length])
          else line.fail!("unknown text option #{option}")
          end
        end
        # A text without length is bounded by its frame; 9P2000.L's u16 length is held in operation_kinds!.
        result[:max] = number(words[1], result[:length_given] ? LENGTHS.fetch(result[:length]) : LIST_MAX, line, constants)
        result[:refuse] = result[:refuse].freeze
        result.freeze
      end

      def list_kind(words, line, kinds, constants)
        element, max_word, maximum, *rest = words
        line.fail!('a list is ELEMENT max N [packed N] [ascending]') unless max_word == 'max'
        result = { form: 'list', element: known_kind(element, line, kinds),
                   max: number(maximum, LIST_MAX, line, constants), ascending: false }
        until rest.empty?
          case rest.shift
          when 'ascending'
            line.fail!('duplicate ascending') if result[:ascending]
            result[:ascending] = true
          when 'packed'
            tuple = kinds[element]
            last = tuple && tuple[:form] == 'tuple' && kinds[tuple.fetch(:elements).last]
            line.fail!('a packed list holds tuples that end in a text') unless last && last[:form] == 'text'
            line.fail!('duplicate packed') if result[:packed]
            result[:packed] = number(rest.shift, 65_536, line, constants)
          else line.fail!('a list is ELEMENT max N [packed N] [ascending]')
          end
        end
        result.freeze
      end

      # frame NAME to|from TAG [slot] KIND
      def frame(line, words, kinds)
        name, direction, tag, *rest = words
        slot = rest.first == 'slot'
        rest = rest.drop(1) if slot
        unless %w[to from].include?(direction) && tag && rest.size == 1
          line.fail!('expected frame NAME to|from TAG [slot] KIND')
        end
        { name: atom_name(name, line: line), direction: direction, tag: atom_name(tag, line: line), slot: slot,
          kind: known_kind(rest.first, line, kinds), line: line }.freeze
      end

      def operation(line, words, children, kinds, constants)
        Model.arity(line, 3)
        name = atom_name(words[0], line: line)
        line.fail!("an operation cannot be named #{name}") if RESERVED_OPERATIONS.include?(name)
        type = number(words[1], 254, line, constants).fetch(:value)
        line.fail!('a request type is even: its reply is the next') unless type.even?
        request = []
        reply = []
        checks = []
        directories = []
        fids = []
        marker = nil
        refused = false
        children.each do |child|
          keyword, *rest = child.words
          case [keyword, rest.size]
          in ['request', 2..3]
            field_name, kind = field(rest.take(2), child, kinds)
            attribute = fid_attribute(rest, child)
            request << [field_name, kind].freeze
            directories << field_name if attribute == 'directory'
            fids << [field_name, attribute].freeze if attribute
          in ['reply', 2] then reply << field(rest, child, kinds)
          in ['reply', 3]
            # A bad name, kind or attribute word is reported as such first.
            field(rest.take(2), child, kinds)
            fid_attribute(rest, child)
            child.fail!('only a request field takes an attribute')
          in ['request' | 'reply', 4..]
            field(rest.take(2), child, kinds)
            child.fail!('a field has at most one attribute')
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
          directories: directories.freeze, fids: fids.freeze,
          checks: checks.map { |item| check(item, line, request, reply, kinds) }.freeze,
          writes: writes(marker, line, request, constants) }.freeze
      end

      def field(words, line, kinds)
        [atom_name(words[0], line: line), known_kind(words[1], line, kinds)].freeze
      end

      # NAME KIND [ATTRIBUTE]: the attribute of a field of kind fid, which it must
      # have, or nil for a field of another kind, which must have none. A field
      # marked "directory" is listed by the generated directory_fids/1, so a server
      # refuses a request whose fid there names anything else from the table, not
      # from a list of its own. An unknown word is reported before a wrong kind,
      # so its row comes before the two that take a known attribute.
      def fid_attribute(words, line)
        name, kind_name, attribute = words
        case [kind_name == FID_KIND, attribute]
        in [true, nil]
          line.fail!("field #{name} of kind #{FID_KIND} states what it names: directory, node or new")
        in [false, nil] then nil
        in [_, String] unless FID_ATTRIBUTES.include?(attribute)
          line.fail!("unknown field attribute #{attribute}")
        in [false, String] then line.fail!("only a field of kind #{FID_KIND} takes an attribute, not #{kind_name}")
        in [true, String] then attribute
        end
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

      # Each "error ATOM NUMBER" member: the atom a reply carries and the
      # nonzero u32 9P2000.L's Rlerror carries for it, each distinct.
      def error_numbers(children, line, constants)
        line.fail!("errors names 1 to #{MAX_ERRORS} errors") unless children.size.between?(1, MAX_ERRORS)
        pairs = children.map do |child|
          child.fail!('expected error ATOM NUMBER') unless child.words.size == 3 && child.words.first == 'error'
          number = number(child.words[2], (1 << 32) - 1, child, constants).fetch(:value)
          child.fail!('an error number is not 0') if number.zero?
          [atom_name(child.words[1], line: child), number].freeze
        end
        line.fail!('duplicate error atom') unless pairs.map(&:first).uniq.size == pairs.size
        line.fail!('duplicate error number') unless pairs.map(&:last).uniq.size == pairs.size
        pairs.freeze
      end

      def known_kind(word, line, kinds)
        name = atom_name(word, line: line)
        known = BASE_KINDS.include?(name) || FRAME_BUILTINS.include?(name) || kinds.key?(name)
        line.fail!("unknown kind #{name}") unless known
        name
      end

      # A number keeps the limit it names, so generated code can say ?P9_IO_MAX
      # rather than 65536.
      def number(word, maximum, line, constants)
        value = Model.numeric(word, constants, line)
        line.fail!("value #{value} outside 0..#{maximum}") unless value.between?(0, maximum)
        { value: value, constant: word.start_with?('@') ? word.delete_prefix('@') : nil }.freeze
      end

      # Every kind roots reach, directly or through another kind.
      def used_kinds(kinds, roots)
        pending = roots.dup
        seen = []
        until pending.empty?
          name = pending.shift
          next if seen.include?(name) || BASE_KINDS.include?(name) || FRAME_BUILTINS.include?(name)

          seen << name
          kind = kinds.fetch(name)
          pending.concat(kind.fetch(:elements, []))
          pending << kind[:element] if kind[:element]
          pending.concat(kind.fetch(:fields, []).map(&:last))
          pending.concat(kind.fetch(:cases, []).flat_map { |item| item.fetch(:fields) })
        end
        seen
      end
    end
  end
end
