# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_contracts'

module Erx
  module ABI
    class DecodeError < Erx::Error
      attr_reader :reason, :field, :offset

      def initialize(reason, field:, offset:)
        @reason = reason.freeze
        @field = field.freeze
        @offset = offset
        super("#{reason}: #{field} at byte #{offset}")
      end
    end

    # One source-driven record codec serves packers and generated host bindings.
    # A record decode is a representation operation; whole-file open below is
    # the trust boundary for bounds, references and declared field constraints.
    class Codec
      attr_reader :schema
      FORMATS = { 'u8' => 'C', 'i8' => 'c', 'u16' => 'v', 'i16' => 's<',
                  'u32' => 'V', 'i32' => 'l<', 'u64' => 'Q<', 'i64' => 'q<' }.freeze

      def initialize(schema)
        @schema = schema
        freeze
      end

      def constant(name)
        item = @schema.constants[name.to_s]
        fail_decode('unknown_constant', 'schema', 0) unless item
        item.value
      end

      def abi_version
        @schema.version
      end

      def member(type_name, member_name)
        type = @schema.types[type_name.to_s]
        unless type.is_a?(EnumType) && type.members.key?(member_name.to_s)
          fail_decode('unknown_member', 'schema', 0)
        end
        type.members.fetch(member_name.to_s)
      end

      def fixed_bytes(name)
        type = @schema.types[name.to_s]
        fail_decode('unknown_fixed_bytes', 'schema', 0) unless type.is_a?(BytesType) && type.fixed
        type.fixed
      end

      def layout_size(name)
        layout(name).size
      end

      def encode_layout(name, values)
        type = layout(name)
        encode_record(type, values, field: type.name).freeze
      end

      def decode_layout(name, bytes, offset: 0, prefix: false)
        type = layout(name)
        unless bytes.is_a?(String) && offset.is_a?(Integer) && offset.between?(0, bytes.bytesize)
          fail_decode('span', type.name, 0)
        end
        maximum = type.size
        maximum += type.tail.maximum * type.tail.type.size if type.tail && !prefix
        # Snapshot only the bounded record, not unrelated archive payloads.
        snapshot = bytes.byteslice(offset, maximum).b.freeze
        decode_record(type, snapshot, 0, field: type.name, prefix: prefix)
      end

      def open(name, bytes)
        reader = @schema.readers.find { |candidate| candidate.name == name.to_s }
        fail_decode('unknown_reader', 'schema', 0) unless reader
        unless bytes.is_a?(String) && bytes.bytesize <= reader.maximum
          fail_decode('length', 'root', 0)
        end
        snapshot = bytes.frozen? && bytes.encoding == Encoding::BINARY ? bytes : bytes.b.freeze
        header = decode_record(reader.root, snapshot, 0, field: 'root', prefix: true)
        if reader.extent && fetch_path(header, reader.extent.fields) != snapshot.bytesize
          fail_decode('length', reader.extent.name, reader.extent.offset)
        end
        check_tables(reader, header, snapshot)
        check_partitions(reader, header, snapshot)
        validate_record(reader, scope: 'root', type: reader.root, value: header,
                        bytes: snapshot, base: 0, header: header)
        reader.tables.each do |scope, table|
          offset = fetch_path(header, table.fetch(:offset_path).fields)
          count = fetch_path(header, table.fetch(:count_path).fields)
          count.times do |index|
            base = offset + index * table.fetch(:type).size
            value = decode_record(table.fetch(:type), snapshot, base, field: scope, prefix: true)
            validate_record(reader, scope: scope, type: table.fetch(:type), value: value,
                            bytes: snapshot, base: base, header: header)
          end
        end
        View.new(codec: self, reader: reader, bytes: snapshot, header: header).freeze
      end

      def table_record(view, table_name, index)
        table = view.reader.tables[table_name.to_s]
        fail_decode('unknown_table', 'schema', 0) unless table
        count = fetch_path(view.header, table.fetch(:count_path).fields)
        unless index.is_a?(Integer) && index >= 0 && index < count
          fail_decode('index', table_name.to_s, 0)
        end
        offset = fetch_path(view.header, table.fetch(:offset_path).fields)
        decode_record(table.fetch(:type), view.bytes, offset + index * table.fetch(:type).size,
                      field: table_name.to_s, prefix: true)
      end

      def table_count(view, table_name)
        table = view.reader.tables[table_name.to_s]
        fail_decode('unknown_table', 'schema', 0) unless table
        fetch_path(view.header, table.fetch(:count_path).fields)
      end

      def string(view, reference, table_name: 'strings')
        table = view.reader.strings[table_name]
        fail_decode('unknown_string_table', 'schema', 0) unless table
        offset = reference.fetch('offset')
        length = reference.fetch('length')
        size = fetch_path(view.header, table.fetch(:count_path).fields)
        unless offset.is_a?(Integer) && length.is_a?(Integer) && offset.between?(0, size) && length.between?(0, size - offset)
          fail_decode('string_range', table_name, 0)
        end
        start = fetch_path(view.header, table.fetch(:offset_path).fields)
        view.bytes.byteslice(start + offset, length).freeze
      rescue KeyError
        fail_decode('string_reference', table_name, 0)
      end

      private

      def layout(name)
        type = @schema.types[name.to_s]
        unless type.is_a?(Layout) && type.storage == 'wire_le'
          fail_decode('unknown_wire_layout', 'schema', 0)
        end
        type
      end

      def fail_decode(reason, field, offset)
        raise DecodeError.new(reason, field: field, offset: offset)
      end

      def encode_record(type, values, field:)
        fail_decode('record', field, 0) unless values.is_a?(Hash)
        names = type.fields.map(&:name)
        names << type.tail.name if type.tail
        fail_decode('unknown_field', field, 0) unless (values.keys - names).empty?
        record = values.dup
        tail_values = nil
        if type.tail
          tail_values = record.fetch(type.tail.name) { fail_decode('missing_field', "#{field}.#{type.tail.name}", type.size) }
          unless tail_values.is_a?(Array) && tail_values.size <= type.tail.maximum
            fail_decode('count', "#{field}.#{type.tail.name}", type.size)
          end
          count = record.fetch(type.tail.count_field, tail_values.size)
          fail_decode('count', "#{field}.#{type.tail.count_field}", 0) unless count == tail_values.size
          record[type.tail.count_field] = count
        end
        result = "\0".b * type.size
        type.fields.each do |member|
          value = if record.key?(member.name)
                    record.fetch(member.name)
                  elsif member.type.is_a?(BytesType) && member.type.fixed && !member.array?
                    member.type.fixed
                  elsif member.zero_mask == (1 << (member.type.size * 8)) - 1 && !member.array?
                    0
                  else
                    fail_decode('missing_field', "#{field}.#{member.name}", member.offset)
                  end
          encoded = encode_field(member, value, field: "#{field}.#{member.name}")
          result[member.offset, member.size] = encoded
        end
        if tail_values
          tail_values.each_with_index do |value, index|
            result << encode_value(type.tail.type, value, field: "#{field}.#{type.tail.name}[#{index}]")
          end
        end
        result
      end

      def encode_field(member, value, field:)
        return encode_value(member.type, value, field: field) unless member.array?
        if member.type.name == 'u8' && value.is_a?(String)
          fail_decode('count', field, 0) unless value.bytesize == member.count
          return value.b
        end
        fail_decode('count', field, 0) unless value.is_a?(Array) && value.size == member.count
        value.map { |item| encode_value(member.type, item, field: field) }.join.b
      end

      def encode_value(type, value, field:)
        if type.is_a?(Layout)
          encode_record(type, value, field: field)
        elsif type.is_a?(BytesType)
          fail_decode('byte_size', field, 0) unless value.is_a?(String) && value.bytesize == type.size
          value.b
        else
          base = type.integer
          unless value.is_a?(Integer) && value.between?(base.minimum, base.maximum)
            fail_decode('integer_range', field, 0)
          end
          [value].pack(FORMATS.fetch(base.name))
        end
      end

      def decode_record(type, bytes, base, field:, prefix:)
        unless base <= bytes.bytesize && type.size <= bytes.bytesize - base
          fail_decode('truncated', field, base)
        end
        record = type.fields.to_h do |member|
          offset = base + member.offset
          value = if member.array? && member.type.name == 'u8'
                    bytes.byteslice(offset, member.count).freeze
                  elsif member.array?
                    Array.new(member.count) do |index|
                      decode_value(member.type, bytes, offset + index * member.type.size, field: "#{field}.#{member.name}")
                    end.freeze
                  else
                    decode_value(member.type, bytes, offset, field: "#{field}.#{member.name}")
                  end
          [member.name, value]
        end
        if type.tail && !prefix
          count = record.fetch(type.tail.count_field)
          remaining = bytes.bytesize - base - type.size
          if count > type.tail.maximum || count > remaining / type.tail.type.size
            fail_decode('tail_extent', "#{field}.#{type.tail.name}", base + type.size)
          end
          record[type.tail.name] = Array.new(count) do |index|
            decode_value(type.tail.type, bytes, base + type.size + index * type.tail.type.size,
                         field: "#{field}.#{type.tail.name}")
          end.freeze
        end
        record.freeze
      end

      def decode_value(type, bytes, offset, field:)
        if type.is_a?(Layout)
          decode_record(type, bytes, offset, field: field, prefix: true)
        elsif type.is_a?(BytesType)
          bytes.byteslice(offset, type.size).freeze
        else
          bytes.byteslice(offset, type.size).unpack1(FORMATS.fetch(type.integer.name))
        end
      end

      def fetch_path(record, fields)
        fields.reduce(record) { |value, field| value.fetch(field) }
      end

      def check_tables(reader, header, bytes)
        cursor = reader.root.size
        reader.order.each do |name|
          table = reader.tables[name] || reader.strings.fetch(name)
          alignment = table.fetch(:alignment)
          padding = (alignment - cursor % alignment) % alignment
          fail_decode('truncated', name, cursor) if padding > bytes.bytesize - cursor
          fail_decode('padding', name, cursor) unless zero?(bytes, cursor, padding)
          cursor += padding
          offset = fetch_path(header, table.fetch(:offset_path).fields)
          count = fetch_path(header, table.fetch(:count_path).fields)
          fail_decode('order', name, cursor) unless offset == cursor
          stride = table[:type] ? table.fetch(:type).size : 1
          if count > table.fetch(:maximum) || count > (bytes.bytesize - cursor) / stride
            fail_decode('extent', name, cursor)
          end
          cursor += count * stride
        end
        fail_decode('trailing', 'root', cursor) unless cursor == bytes.bytesize
      end

      def validate_record(reader, scope:, type:, value:, bytes:, base:, header:)
        pending = [[type, value, [], 0]]
        until pending.empty?
          current_type, current_value, prefix, relative = pending.pop
          current_type.padding.each do |offset, length|
            fail_decode('reserved', scoped(scope, prefix + ['padding']), base + relative + offset) unless zero?(bytes, base + relative + offset, length)
          end
          current_type.fields.each do |member|
            fields = prefix + [member.name]
            member_value = current_value.fetch(member.name)
            offset = relative + member.offset
            if member.type.is_a?(Layout) && !member.array?
              pending << [member.type, member_value, fields, offset]
              next
            end
            next unless active?(reader, scope, fields, value, header)
            if member.array?
              elements = member_value.is_a?(String) ? member_value.bytes : member_value
              elements.each_with_index do |element, index|
                validate_leaf(member, element, reader.source_role,
                              field: scoped(scope, fields), offset: base + offset + index * member.type.size)
              end
            else
              validate_leaf(member, member_value, reader.source_role,
                            field: scoped(scope, fields), offset: base + offset)
            end
          end
        end
        reader.rules.each do |rule|
          path = rule[:path] || rule[:offset] || rule.fetch(:tag)
          next unless path.scope == scope
          if rule[:guard]
            condition = rule.fetch(:guard)
            next unless path_value(condition.fetch(:tag), value, header) == condition.fetch(:value)
          end
          unless %w[optional choice].include?(rule.fetch(:kind))
            next unless active?(reader, scope, path.fields, value, header)
          end
          check_rule(rule, reader, value: value, header: header, bytes: bytes, base: base)
        end
      end

      def check_partitions(reader, header, bytes)
        reader.rules.each do |rule|
          next unless rule.fetch(:kind) == 'partition'
          path = rule.fetch(:offset)
          owners = reader.tables.fetch(path.scope)
          target = reader.tables.fetch(rule.fetch(:table))
          owner_start = fetch_path(header, owners.fetch(:offset_path).fields)
          owner_count = fetch_path(header, owners.fetch(:count_path).fields)
          target_start = fetch_path(header, target.fetch(:offset_path).fields)
          target_count = fetch_path(header, target.fetch(:count_path).fields)
          covered = 0
          owner_count.times do |index|
            base = owner_start + index * owners.fetch(:type).size
            record = decode_record(owners.fetch(:type), bytes, base, field: path.scope, prefix: true)
            offset = path_value(path, record, header)
            count = path_value(rule.fetch(:count), record, header)
            unless offset == target_start + covered * target.fetch(:type).size && count <= target_count - covered
              fail_decode('partition', path.name, base + path.offset)
            end
            covered += count
          end
          unless covered == target_count
            fail_decode('partition', path.name, target_start + covered * target.fetch(:type).size)
          end
        end
      end

      def scoped(scope, fields)
        ([scope == 'root' ? 'root' : "#{scope}[]"] + fields).join('.')
      end

      def active?(reader, scope, fields, value, header)
        reader.rules.all? do |rule|
          case rule.fetch(:kind)
          when 'optional'
            path = rule.fetch(:path)
            next true unless path.scope == scope && fields.take(path.fields.size) == path.fields
            (path_value(rule.fetch(:flags), value, header) & rule.fetch(:mask)) != 0
          when 'choice'
            next true unless rule.fetch(:tag).scope == scope
            selected = rule.fetch(:fields).find { |path| fields.take(path.fields.size) == path.fields }
            next true unless selected
            tag = path_value(rule.fetch(:tag), value, header)
            rule.fetch(:cases).fetch(tag, []).any? { |path| path.name == selected.name }
          else true
          end
        end
      end

      def path_value(path, value, header)
        fetch_path(path.scope == 'root' ? header : value, path.fields)
      end

      def validate_leaf(member, value, role, field:, offset:)
        type = member.type
        if type.is_a?(BytesType)
          fail_decode('value', field, offset) if type.fixed && value != type.fixed
          fail_decode('reserved', field, offset) if member.zero_mask != 0 && !value.bytes.all?(&:zero?)
          return
        end
        if type.is_a?(ScalarType)
          unless value.between?(type.minimum, type.maximum) && (value % type.multiple).zero?
            fail_decode('range', field, offset)
          end
        elsif type.is_a?(EnumType)
          valid = if type.allowed
                    type.allowed.include?(value)
                  elsif type.flags
                    (value & ~type.mask).zero?
                  else
                    type.members.value?(value)
                  end
          fail_decode(type.flags ? 'flags' : 'tag', field, offset) unless valid
        end
        unsigned = value & ((1 << (type.size * 8)) - 1)
        fail_decode('reserved', field, offset) unless (unsigned & member.zero_mask).zero?
        if role && member.input_masks.key?(role)
          fail_decode('ownership', field, offset) unless (unsigned & ~member.input_masks.fetch(role)).zero?
        end
      end

      def check_rule(rule, reader, value:, header:, bytes:, base:)
        path = rule[:path] || rule[:offset] || rule.fetch(:tag)
        datum = path_value(path, value, header)
        offset = base + path.offset
        case rule.fetch(:kind)
        when 'value'
          fail_decode('value', path.name, offset) unless datum == rule.fetch(:values).first
        when 'range'
          fail_decode('range', path.name, offset) unless datum.between?(*rule.fetch(:values))
        when 'index'
          table = reader.tables.fetch(rule.fetch(:table))
          count = fetch_path(header, table.fetch(:count_path).fields)
          fail_decode('index', path.name, offset) unless datum < count || datum == rule[:absent]
        when 'slice', 'partition'
          table = reader.tables.fetch(rule.fetch(:table))
          first = fetch_path(header, table.fetch(:offset_path).fields)
          count = fetch_path(header, table.fetch(:count_path).fields)
          size = table.fetch(:type).size
          length = path_value(rule.fetch(:count), value, header)
          relative = datum - first
          unless relative >= 0 && (relative % size).zero? && relative / size <= count && length <= count - relative / size
            fail_decode('slice', path.name, offset)
          end
        when 'string'
          check_string(rule, reader, value: value, header: header, bytes: bytes, base: base)
        when 'optional'
          present = (path_value(rule.fetch(:flags), value, header) & rule.fetch(:mask)) != 0
          fail_decode('inactive', path.name, offset) unless present || zero?(bytes, offset, path.field.size)
        when 'choice'
          active = rule.fetch(:cases)[datum]
          fail_decode('tag', path.name, offset) unless active
          rule.fetch(:fields).each do |candidate|
            next if active.any? { |selected| selected.name == candidate.name }
            fail_decode('inactive', candidate.name, base + candidate.offset) unless zero?(bytes, base + candidate.offset, candidate.field.size)
          end
        end
      end

      def check_string(rule, reader, value:, header:, bytes:, base:)
        offset_path = rule.fetch(:offset)
        offset = path_value(offset_path, value, header)
        length = path_value(rule.fetch(:count), value, header)
        table = reader.strings.fetch(rule.fetch(:table))
        table_size = fetch_path(header, table.fetch(:count_path).fields)
        unless offset <= table_size && length <= table_size - offset && length <= rule.fetch(:maximum) && (rule.fetch(:empty) || length.positive?)
          fail_decode('string_range', offset_path.name, base + offset_path.offset)
        end
        return if length.zero? && rule.fetch(:empty)
        first = fetch_path(header, table.fetch(:offset_path).fields)
        text = bytes.byteslice(first + offset, length)
        fail_decode('string_class', offset_path.name, base + offset_path.offset) unless valid_string?(rule.fetch(:class), text)
      end

      def valid_string?(kind, bytes)
        case kind
        when 'bytes' then true
        when 'identifier' then bytes.bytesize.between?(1, 63) && bytes.match?(/\A[a-z0-9][a-z0-9_-]*\z/)
        when 'utf8'
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          text.valid_encoding? && text.codepoints.none? { |point| point < 0x20 || point.between?(0x7f, 0x9f) }
        when 'dt_path', 'namespace_path'
          valid_path?(bytes, clean: kind == 'dt_path')
        when 'args', 'env'
          return true if bytes.empty?
          return false unless bytes.end_with?("\0")
          return true if kind == 'args'
          keys = bytes.split("\0", -1).take(bytes.count("\0")).map do |entry|
            key, separator, = entry.partition('=')
            return false if key.empty? || separator.empty?
            key
          end
          keys.uniq.size == keys.size
        else false
        end
      end

      def valid_path?(bytes, clean:)
        return false unless bytes.start_with?('/') && !bytes.include?("\0")
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return false unless text.valid_encoding?
        return false if clean && text.codepoints.any? { |point| point < 0x20 || point.between?(0x7f, 0x9f) }
        return true if bytes == '/'
        bytes.split('/', -1).drop(1).none? { |part| ['', '.', '..'].include?(part) }
      end

      def zero?(bytes, offset, length)
        bytes.byteslice(offset, length).bytes.all?(&:zero?)
      end
    end

    # Tables remain lazy after complete validation, so a large manifest does
    # not force the host tool to retain a Ruby object for every record at once.
    class View
      attr_reader :reader, :bytes, :header

      def initialize(codec:, reader:, bytes:, header:)
        @codec = codec
        @reader = reader
        @bytes = bytes
        @header = header
      end

      def count(table)
        @codec.table_count(self, table)
      end

      def fetch(table, index)
        @codec.table_record(self, table, index)
      end

      def each(table)
        return enum_for(__method__, table) unless block_given?
        count(table).times { |index| yield fetch(table, index) }
        self
      end

      def string(reference, table: 'strings')
        @codec.string(self, reference, table_name: table)
      end
    end
  end
end
