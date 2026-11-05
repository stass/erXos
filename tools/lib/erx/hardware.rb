# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rexml/parsers/pullparser'
require 'digest'
require 'tmpdir'
require 'fileutils'
require_relative 'json_input'
require_relative 'bounded_file'
require_relative 'output_directory'

module Erx
  module Hardware
    XmlNode = Struct.new(:name, :attributes, :text, :children, keyword_init: true)
    Field = Struct.new(:name, :offset, :width, :access, :clear, :values, keyword_init: true)
    Register = Struct.new(:name, :offset, :width, :access, :read_action, :fields, :holds_device_address, :count, :stride,
                          keyword_init: true)
    Device = Struct.new(:name, :size, :registers, keyword_init: true)
    IDENTIFIER = /\A[A-Za-z][A-Za-z0-9_]*\z/
    ARRAY_NAME = /\A(.*)\[%s\]\z/
    ELEMENTS_MAX = 256
    # Headers the device table owns under include/erx/hw, so no peripheral may be named for one.
    DEVICE_HEADERS = %w[device_types device_table device_access].freeze
    CONTAINERS = %w[device peripherals peripheral addressBlock registers register fields field
                    enumeratedValues enumeratedValue].freeze
    module_function

    # REXML handles XML syntax. This bounded tree has no entity or DTD state
    # and never recursively follows an input-controlled element depth.
    def xml(bytes)
      raise Error, 'SVD exceeds its byte bound' unless bytes.is_a?(String) && bytes.bytesize <= 4 * 1024 * 1024
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && !text.include?("\0") &&
             !text.include?('<!DOCTYPE') && !text.include?('<!ENTITY')
        raise Error, 'SVD requires UTF-8 without document types or entities'
      end
      declarations = text.scan(/<\?xml\s+([^?]*)\?>/m).flatten
      declarations.each do |declaration|
        if declaration.match?(/\bencoding\b/) && !declaration.match?(/\bencoding\s*=\s*(['"])UTF-8\1/i)
          raise Error, 'SVD XML declaration must specify UTF-8'
        end
      end
      parser = REXML::Parsers::PullParser.new(text)
      stack = []
      root = nil
      count = 0
      while parser.has_next?
        event = parser.pull
        case event.event_type
        when :start_element
          count += 1
          raise Error, 'SVD element/depth bound exceeded' if count > 65_536 || stack.size >= 32
          node = XmlNode.new(name: event[0], attributes: event[1], text: ''.dup, children: [])
          allowed_attributes = node.name == 'device' ? ['schemaVersion'] : []
          unless (node.attributes.keys - allowed_attributes).empty?
            raise Error, 'SVD attributes require explicit semantic support'
          end
          if stack.empty?
            raise Error, 'SVD has multiple roots' if root
            root = node
          else
            stack.last.children << node
          end
          stack << node
        when :end_element
          raise Error, 'SVD has unmatched element' unless stack.last && stack.last.name == event[0]
          closed = stack.pop
          if CONTAINERS.include?(closed.name)
            raise Error, 'text in SVD container is unsupported' unless closed.text.strip.empty?
          elsif !closed.children.empty?
            raise Error, 'nested SVD scalar content is unsupported'
          end
        when :text
          if stack.empty?
            raise Error, 'text outside SVD root' unless event[1].to_s.strip.empty?
          else
            stack.last.text << event[1].to_s
          end
        when :xmldecl, :comment, :end_document
          next
        else
          raise Error, "unsupported SVD XML event: #{event.event_type}"
        end
      end
      raise Error, 'incomplete SVD tree' unless root && stack.empty?
      root
    rescue REXML::ParseException, ArgumentError, Encoding::CompatibilityError => error
      raise Error, "invalid SVD XML: #{error.message}"
    end

    def children(node, name)
      node.children.select { |child| child.name == name }
    end

    def child(node, name, required: true)
      values = children(node, name)
      raise Error, "duplicate SVD #{name}" if values.size > 1
      raise Error, "missing SVD #{name}" if required && values.empty?
      values.first
    end

    def text(node, name, default: nil)
      value = child(node, name, required: default.nil?)
      raise Error, 'nested SVD scalar content is unsupported' if value && !value.children.empty?
      value ? value.text.strip : default
    end

    def number(value, maximum: (1 << 64) - 1)
      unless value.is_a?(String) && /\A(?:0x[0-9A-Fa-f]+|[0-9]+)\z/.match?(value) && value.bytesize <= 32
        raise Error, 'invalid SVD unsigned integer'
      end
      result = Integer(value, value.start_with?('0x') ? 16 : 10)
      raise Error, 'SVD integer exceeds its width' if result > maximum
      result
    end

    def identifier(value)
      unless value.is_a?(String) && value.bytesize.between?(1, 63) && IDENTIFIER.match?(value)
        raise Error, 'invalid or overlong SVD identifier'
      end
      value.freeze
    end

    def known_elements(node, allowed:)
      unknown = node.children.map(&:name) - allowed
      raise Error, "unsupported SVD element: #{unknown.first}" unless unknown.empty?
      attributes = node.name == 'device' ? ['schemaVersion'] : []
      unless (node.attributes.keys - attributes).empty?
        raise Error, 'SVD attributes require explicit semantic support'
      end
    end

    def access(value)
      raise Error, 'unsupported SVD register access' unless %w[read-only write-only read-write].include?(value)
      value.freeze
    end

    def parse_svd(bytes)
      root = xml(bytes)
      raise Error, 'SVD root must be device' unless root.name == 'device'
      raise Error, 'unsupported SVD schema version' unless root.attributes['schemaVersion'] == '1.3'
      known_elements(root, allowed: %w[name version description addressUnitBits width peripherals])
      raise Error, 'SVD address units must be bytes' unless number(text(root, 'addressUnitBits')) == 8
      default_width = number(text(root, 'width'))
      peripherals = child(root, 'peripherals')
      raise Error, 'SVD input profile requires one peripheral' unless peripherals.children.size == 1
      peripheral = child(peripherals, 'peripheral')
      known_elements(peripheral, allowed: %w[name description baseAddress addressBlock registers])
      raise Error, 'SVD peripheral base must be relative zero' unless number(text(peripheral, 'baseAddress')) == 0
      block = child(peripheral, 'addressBlock')
      known_elements(block, allowed: %w[offset size usage])
      raise Error, 'SVD address block must start at zero' unless number(text(block, 'offset')) == 0
      raise Error, 'SVD address block must hold registers' unless text(block, 'usage') == 'registers'
      size = number(text(block, 'size'), maximum: 1024 * 1024)
      registers = child(peripheral, 'registers')
      known_elements(registers, allowed: ['register'])
      list = registers.children.map { |node| parse_register(node, default_width: default_width, block_size: size) }
      raise Error, 'SVD requires 1..4096 registers' unless list.size.between?(1, 4096)
      names = list.map { |register| register.name.downcase }
      raise Error, 'SVD register names collide' unless names.uniq == names
      element_ranges(list).each_cons(2) do |left, right|
        raise Error, 'SVD register ranges overlap' if left.end > right.begin
      end
      Device.new(name: identifier(text(peripheral, 'name')), size: size,
                 registers: list.freeze).freeze.then do |device|
        validate_symbols(device)
        device
      end
    end

    # The byte range of each register, one for each element of an array, in address order.
    def element_ranges(registers)
      registers.flat_map do |register|
        Array.new(register.count) do |index|
          first = register.offset + index * register.stride
          first...(first + register.width / 8)
        end
      end.sort_by(&:begin)
    end

    # The mark erXos adds to the SVD profile: whether a register holds a device address, such
    # as a ring's base, which only erx_device's address function may write. A register
    # without it is refused, so no one adds a register without deciding.
    def device_address_mark(node)
      case text(node, 'holdsDeviceAddress', default: '')
      when 'true' then true
      when 'false' then false
      else raise Error, 'SVD register lacks its holdsDeviceAddress mark'
      end
    end

    # An array is `NAME[%s]` with dim and dimIncrement, one element per index from zero.
    def register_shape(node, width:)
      name = text(node, 'name')
      if child(node, 'dim', required: false).nil?
        raise Error, 'SVD dimIncrement without dim' if child(node, 'dimIncrement', required: false)

        return [name, 1, 0]
      end

      base = name[ARRAY_NAME, 1]
      count = number(text(node, 'dim'), maximum: ELEMENTS_MAX)
      stride = number(text(node, 'dimIncrement'), maximum: 1024 * 1024)
      unless base && count >= 2 && stride >= width / 8 && stride % (width / 8) == 0
        raise Error, 'invalid SVD register array'
      end
      [base, count, stride]
    end

    def parse_register(node, default_width:, block_size:)
      known_elements(node, allowed: %w[name description addressOffset size access readAction fields
                                       holdsDeviceAddress dim dimIncrement])
      width = number(text(node, 'size', default: default_width.to_s))
      raise Error, 'SVD access width must be 32 or 64 bits' unless [32, 64].include?(width)
      offset = number(text(node, 'addressOffset'), maximum: block_size)
      name, count, stride = register_shape(node, width: width)
      span = (count - 1) * stride + width / 8
      unless offset % (width / 8) == 0 && offset <= block_size && span <= block_size - offset
        raise Error, 'SVD register is outside its aligned block'
      end
      mode = access(text(node, 'access'))
      action = text(node, 'readAction', default: '')
      raise Error, 'unsupported SVD read action' unless ['', 'clear', 'set', 'modify', 'modifyExternal'].include?(action)
      fields_node = child(node, 'fields')
      known_elements(fields_node, allowed: ['field'])
      fields = fields_node.children.map { |field| parse_field(field, width: width, register_access: mode) }
      raise Error, 'SVD register requires fields' if fields.empty?
      occupied = 0
      names = []
      fields.each do |field|
        mask = ((1 << field.width) - 1) << field.offset
        raise Error, 'SVD fields overlap' unless (occupied & mask).zero?
        occupied |= mask
        names << field.name.downcase
      end
      raise Error, 'SVD field names collide' unless names.uniq == names
      writable = fields.reject { |field| field.access == 'read-only' }
      if writable.any?(&:clear) && writable.any? { |field| !field.clear }
        raise Error, 'mixed SVD write semantics require an explicit access sequence'
      end
      Register.new(name: identifier(name), offset: offset, width: width, access: mode, read_action: action.freeze,
                   fields: fields.freeze, holds_device_address: device_address_mark(node), count: count, stride: stride).freeze
    end

    def parse_field(node, width:, register_access:)
      known_elements(node, allowed: %w[name description bitOffset bitWidth access modifiedWriteValues enumeratedValues])
      offset = number(text(node, 'bitOffset'), maximum: width)
      bits = number(text(node, 'bitWidth'), maximum: width)
      raise Error, 'SVD field exceeds register width' unless bits.positive? && offset < width && bits <= width - offset
      mode = access(text(node, 'access', default: register_access))
      if register_access == 'read-only' && mode != 'read-only' || register_access == 'write-only' && mode != 'write-only'
        raise Error, 'SVD field access exceeds its register'
      end
      modified = text(node, 'modifiedWriteValues', default: '')
      raise Error, 'unsupported SVD write semantics' unless ['', 'oneToClear'].include?(modified)
      raise Error, 'read-only SVD field cannot be cleared' if modified == 'oneToClear' && mode == 'read-only'
      values_node = child(node, 'enumeratedValues', required: false)
      values = {}
      if values_node
        known_elements(values_node, allowed: ['enumeratedValue'])
        values_node.children.each do |value|
          known_elements(value, allowed: %w[name description value])
          name = identifier(text(value, 'name'))
          raise Error, 'duplicate SVD enumerated name' if values.key?(name.downcase)
          values[name.downcase] = number(text(value, 'value'), maximum: (1 << bits) - 1)
        end
      end
      Field.new(name: identifier(text(node, 'name')), offset: offset, width: bits,
                access: mode, clear: modified == 'oneToClear', values: values.freeze).freeze
    end

    def c_mask(width, register_width:)
      value = (1 << width) - 1
      c_integer(value, width: register_width)
    end

    def c_integer(value, width:)
      "UINT#{width}_C(0x#{value.to_s(16)})"
    end

    # Underscores make distinct source paths capable of naming the same C
    # member. Check the complete emitted namespace rather than each level.
    def generated_symbols(device)
      symbols = device.registers.flat_map do |register|
        name = "erx_#{device.name.downcase}_#{register.name.downcase}"
        accessors = []
        accessors << "#{name}_read" unless register.access == 'write-only'
        accessors << "#{name}_write" unless register.access == 'read-only'
        fields = register.fields.flat_map do |field|
          member = "#{name}_#{field.name.downcase}"
          values = field.values.keys.map { |label| "#{member.upcase}_#{label.upcase}" }
          values << "#{member}_get" unless field.access == 'write-only'
          values << "#{member}_#{field.clear ? 'clear' : 'set'}" unless field.access == 'read-only'
          values
        end
        accessors + fields
      end
      (["ERX_HW_#{device.name.upcase}_H"] + symbols).freeze
    end

    def validate_symbols(device)
      symbols = generated_symbols(device)
      raise Error, 'SVD generated C symbols collide' unless symbols.uniq == symbols
    end

    def mmio_header
      <<~C
        /* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
         * SPDX-License-Identifier: BSD-2-Clause
         * Generated by tools/gen_hw.rb. Do not edit.
         */
        #ifndef ERX_MMIO_H
        #define ERX_MMIO_H
        #include <stddef.h>
        #include <stdint.h>
        typedef struct erx_mmio erx_mmio_t;
        struct erx_mmio {
        \tvolatile uint8_t *base;
        \tsize_t length;
        };
        #endif
      C
    end

    def device_header(device)
      prefix = "erx_#{device.name.downcase}"
      guard = "ERX_HW_#{device.name.upcase}_H"
      lines = ["/* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>",
               ' * SPDX-License-Identifier: BSD-2-Clause',
               ' * Generated by tools/gen_hw.rb. Do not edit.', ' */',
               "#ifndef #{guard}", "#define #{guard}", '#include <stdbool.h>',
               '#include <stddef.h>', '#include <stdint.h>', '#include "erx/mmio.h"', '']
      device.registers.each do |register|
        type = "uint#{register.width}_t"
        name = "#{prefix}_#{register.name.downcase}"
        bytes = register.width / 8
        array = register.count > 1
        index = array ? ', uint32_t index' : ''
        last = register.offset + (register.count - 1) * register.stride + bytes
        at = array ? "#{register.offset} + index * #{register.stride}" : register.offset.to_s
        in_range = array ? "index >= #{register.count} || " : ''
        readable = register.access != 'write-only'
        writable = register.access != 'read-only'
        if readable
          lines.concat(['static inline bool', "#{name}_read(erx_mmio_t device#{index}, #{type} *out)", '{',
                        "\tif (#{in_range}out == NULL || device.base == NULL || device.length < #{last} ||",
                        "\t    (uintptr_t)device.base % #{bytes} != 0)", "\t\treturn (false);",
                        "\t*out = *(volatile #{type} *)(device.base + #{at});",
                        "\treturn (true);", '}', ''])
        end
        if writable
          lines.concat(['static inline bool', "#{name}_write(erx_mmio_t device#{index}, #{type} value)", '{',
                        "\tif (#{in_range}device.base == NULL || device.length < #{last} ||",
                        "\t    (uintptr_t)device.base % #{bytes} != 0 ||",
                        "\t    (value & ~#{c_integer(writable_mask(register), width: register.width)}) != 0)",
                        "\t\treturn (false);", "\t*(volatile #{type} *)(device.base + #{at}) = value;",
                        "\treturn (true);", '}', ''])
        end
        register.fields.each do |field|
          field_name = "#{name}_#{field.name.downcase}"
          mask = c_mask(field.width, register_width: register.width)
          field.values.each do |label, value|
            lines << "#define #{field_name.upcase}_#{label.upcase} UINT#{register.width}_C(#{value})"
          end
          if field.access != 'write-only'
            lines.concat(['static inline ' + type, "#{field_name}_get(#{type} word)", '{',
                          "\treturn ((word >> #{field.offset}) & #{mask});", '}', ''])
          end
          next if field.access == 'read-only'
          if field.clear
            lines.concat(['static inline bool', "#{field_name}_clear(erx_mmio_t device#{index}, #{type} value)", '{',
                          "\tif ((value & ~#{mask}) != 0)", "\t\treturn (false);",
                          "\treturn (#{name}_write(device#{array ? ', index' : ''}, value << #{field.offset}));", '}', ''])
          else
            lines.concat(['static inline bool', "#{field_name}_set(#{type} word, #{type} value, #{type} *out)", '{',
                          "\tif (out == NULL || (value & ~#{mask}) != 0)", "\t\treturn (false);",
                          "\t*out = (word & ~(#{mask} << #{field.offset})) | (value << #{field.offset});",
                          "\treturn (true);", '}', ''])
          end
        end
      end
      lines.concat(['#endif', '']).join("\n")
    end

    def writable_mask(register)
      register.fields.reject { |field| field.access == 'read-only' }.sum { |field| ((1 << field.width) - 1) << field.offset }
    end

    # Whether a field of the register may be replaced by reading the word and writing it back:
    # the read has no side effect, and some bit is writable (a register with none takes a write
    # that means something other than replacement, as a write to PL011's RSR clears its errors).
    def plain_update?(register)
      register.access == 'read-write' && register.read_action.empty? && !writable_mask(register).zero? &&
        register.fields.none? { |field| field.clear || field.access == 'write-only' }
    end

    def generated_header(guard, body, includes: [])
      ['/* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>', ' * SPDX-License-Identifier: BSD-2-Clause',
       ' * Generated by tools/gen_hw.rb. Do not edit.', ' */', "#ifndef #{guard}", "#define #{guard}",
       *includes.map { |file| "#include #{file}" }, '', *body, '#endif', ''].join("\n")
    end

    # The shapes of the device table, and the most any peripheral needs, so a device's record
    # holds its atoms in place.
    def device_types_header(devices)
      registers_max = devices.map { |device| device.registers.size }.max
      fields_max = devices.map { |device| device.registers.sum { |register| register.fields.size } }.max
      generated_header('ERX_HW_DEVICE_TYPES_H', <<~C.lines(chomp: true), includes: %w[<stdbool.h> <stdint.h>])
        #define ERX_DEVICE_REGISTERS_MAX #{registers_max}u
        #define ERX_DEVICE_FIELDS_MAX #{fields_max}u

        typedef enum erx_device_access {
        \tERX_DEVICE_READ_ONLY,
        \tERX_DEVICE_WRITE_ONLY,
        \tERX_DEVICE_READ_WRITE
        } erx_device_access_t;

        typedef struct erx_device_field {
        \tconst char\t*name;
        \tuint64_t\tmask;
        \tuint8_t\t\tshift;
        \tuint8_t\t\taccess;
        \tbool\t\tclear;
        } erx_device_field_t;

        typedef struct erx_device_register {
        \tconst char\t*name;
        \tuint64_t\twritable;
        \tuint32_t\toffset;
        \tuint32_t\tcount;
        \tuint32_t\tstride;
        \tuint32_t\tfirst_field;
        \tuint32_t\tfield_count;
        \tuint8_t\t\twindow;
        \tuint8_t\t\twidth;
        \tuint8_t\t\taccess;
        \tbool\t\tholds_device_address;
        \tbool\t\tplain_update;
        } erx_device_register_t;

        typedef struct erx_device_peripheral {
        \tconst char\t\t\t*name;
        \tconst erx_device_register_t\t*registers;
        \tconst erx_device_field_t\t*fields;
        \tuint64_t\t\t\twindow_size;
        \tuint32_t\t\t\tregister_count;
        \tuint32_t\t\t\tfield_count;
        } erx_device_peripheral_t;
      C
    end

    ACCESS_NAMES = { 'read-only' => 'ERX_DEVICE_READ_ONLY', 'write-only' => 'ERX_DEVICE_WRITE_ONLY',
                     'read-write' => 'ERX_DEVICE_READ_WRITE' }.freeze

    def table_field(field, width:)
      mask = c_integer(((1 << field.width) - 1) << field.offset, width: width)
      "\t{ .name = \"#{field.name.downcase}\", .mask = #{mask}, .shift = #{field.offset}, " \
        ".access = #{ACCESS_NAMES.fetch(field.access)}, .clear = #{field.clear} },"
    end

    def table_register(register, first_field:)
      "\t{ .name = \"#{register.name.downcase}\", .writable = #{c_integer(writable_mask(register), width: register.width)}, " \
        ".offset = #{register.offset}, .count = #{register.count}, .stride = #{register.stride}, " \
        ".first_field = #{first_field}, .field_count = #{register.fields.size}, .window = 0, .width = #{register.width}, " \
        ".access = #{ACCESS_NAMES.fetch(register.access)}, .holds_device_address = #{register.holds_device_address}, " \
        ".plain_update = #{plain_update?(register)} },"
    end

    def table_device(device)
      prefix = "erx_device_#{device.name.downcase}"
      fields = device.registers.flat_map { |register| register.fields.map { |field| table_field(field, width: register.width) } }
      firsts = device.registers.reduce([0]) { |sums, register| sums + [sums.last + register.fields.size] }
      registers = device.registers.zip(firsts).map { |register, first| table_register(register, first_field: first) }
      ["static const erx_device_field_t #{prefix}_fields[] = {", *fields, '};', '',
       "static const erx_device_register_t #{prefix}_registers[] = {", *registers, '};', '']
    end

    # Static data for the one source that includes it, erx_device_core.c.
    def device_table_header(devices)
      entries = devices.map do |device|
        prefix = "erx_device_#{device.name.downcase}"
        "\t{ .name = \"#{device.name.downcase}\", .registers = #{prefix}_registers, .fields = #{prefix}_fields, " \
          ".window_size = #{device.size}, .register_count = #{device.registers.size}, " \
          ".field_count = #{device.registers.sum { |register| register.fields.size }} },"
      end
      generated_header('ERX_HW_DEVICE_TABLE_H', [*devices.flat_map { |device| table_device(device) },
                                                 'static const erx_device_peripheral_t erx_device_peripherals[] = {',
                                                 *entries, '};', ''], includes: ['"erx/hw/device_types.h"'])
    end

    # The one volatile access of each width the table holds, for erx_device.c alone: the funnel
    # that the chokepoint device-register-access keeps.
    def device_access_header
      body = [32, 64].flat_map do |width|
        type = "uint#{width}_t"
        ["static inline #{type}", "erx_device_access_load#{width}(volatile uint8_t *window, uint64_t offset)", '{',
         "\treturn (*(volatile #{type} *)(void *)(window + offset));", '}', '',
         'static inline void', "erx_device_access_store#{width}(volatile uint8_t *window, uint64_t offset, #{type} value)", '{',
         "\t*(volatile #{type} *)(void *)(window + offset) = value;", '}', '']
      end
      generated_header('ERX_HW_DEVICE_ACCESS_H', body, includes: ['<stdint.h>'])
    end

    # All parsing and rendering completes before the first output is written.
    # The directory is owned by this frontend, making orphan checks explicit.
    def output_plan(root:)
      devices = Dir.glob(File.join(root, 'hw/svd/**/*.svd')).sort.map do |path|
        parse_svd(BoundedFile.read(path, maximum: 4 * 1024 * 1024))
      end
      raise Error, 'hardware input inventory is empty' if devices.empty?
      names = devices.map { |device| device.name.downcase }
      raise Error, 'SVD device names collide' unless names.uniq == names
      raise Error, 'SVD device is named for a device table header' unless (names & DEVICE_HEADERS).empty?
      symbols = %w[ERX_MMIO_H erx_mmio erx_mmio_t] + devices.flat_map { |device| generated_symbols(device) }
      raise Error, 'SVD combined C symbols collide' unless symbols.uniq == symbols
      tables = { 'include/erx/mmio.h' => mmio_header.freeze,
                 'include/erx/hw/device_types.h' => device_types_header(devices).freeze,
                 'include/erx/hw/device_table.h' => device_table_header(devices).freeze,
                 'include/erx/hw/device_access.h' => device_access_header.freeze }
      devices.each_with_object(tables) do |device, files|
        files["include/erx/hw/#{device.name.downcase}.h"] = device_header(device).freeze
      end.freeze
    rescue SystemCallError => error
      raise Error, "cannot read hardware input: #{error.message}"
    end

    def output_inventory(root:)
      directory = File.join(root, 'include/erx/hw')
      raise Error, 'hardware output directory is a symlink' if File.symlink?(directory)
      paths = ['include/erx/mmio.h']
      if File.directory?(directory)
        Dir.children(directory).sort.each do |name|
          path = File.join(directory, name)
          stat = File.lstat(path)
          raise Error, 'unexpected directory in hardware output inventory' if stat.directory?
          paths << path.delete_prefix(root + '/')
        end
      end
      paths.sort
    end

    def check_outputs(plan, root:)
      root = File.realpath(root)
      validate_output_locations(plan, root: root)
      stale = (plan.keys | output_inventory(root: root)).sort.select do |relative|
        path = File.join(root, relative)
        !plan.key?(relative) || !File.file?(path) || File.symlink?(path) ||
          BoundedFile.read(path, maximum: plan.fetch(relative).bytesize) != plan.fetch(relative)
      end
      raise Error, "hardware generation drift: #{stale.join(', ')}" unless stale.empty?
      true
    rescue SystemCallError => error
      raise Error, "cannot check hardware outputs: #{error.message}"
    end

    def publish_outputs(plan, root:)
      root = File.realpath(root)
      validate_output_locations(plan, root: root)
      inventory = output_inventory(root: root)
      plan.each do |relative, bytes|
        path = File.join(root, relative)
        directory = OutputDirectory.prepare(root: root, path: File.dirname(path))
        temporary = File.join(directory, ".#{File.basename(path)}.#{Process.pid}.tmp")
        created = false
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
            created = true
            file.write(bytes)
          end
          File.rename(temporary, path)
        ensure
          File.unlink(temporary) if created && File.file?(temporary) && !File.symlink?(temporary)
        end
      end
      (inventory - plan.keys).each { |relative| File.unlink(File.join(root, relative)) }
      true
    rescue SystemCallError => error
      raise Error, "cannot publish hardware outputs: #{error.message}"
    end

    def validate_output_locations(plan, root:)
      valid = plan.is_a?(Hash) && plan.key?('include/erx/mmio.h') && plan.all? do |path, bytes|
        path.is_a?(String) && path.ascii_only? &&
          (path == 'include/erx/mmio.h' || /\Ainclude\/erx\/hw\/[a-z][a-z0-9_]{0,62}\.h\z/.match?(path)) &&
          bytes.is_a?(String) && !bytes.empty? && bytes.ascii_only?
      end
      raise Error, 'invalid hardware output plan' unless valid
      plan.keys.each do |relative|
        OutputDirectory.check(root: root, path: File.dirname(File.join(root, relative)))
        path = File.join(root, relative)
        if File.exist?(path) && !File.symlink?(path) && !File.file?(path)
          raise Error, 'hardware output destination is not a regular file'
        end
      end
      true
    end
    private_class_method :validate_output_locations
  end
end
