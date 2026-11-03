# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'json_input'
require_relative 'runner'

module Erx
  class StackGraphError < Error; end

  # Readers of the three tool outputs the stack graph is built from: clang's
  # -fstack-usage records, llvm-readobj's JSON listing of an object's
  # sections, symbols and relocations, and llvm-objdump's disassembly. Each
  # reader is pure and bounded, and refuses any line or field it does not
  # recognize with a diagnostic naming the object, so a tool that changes its
  # output format stops the proof instead of thinning the graph.
  module StackGraphInput
    MAX_LINE_BYTES = 4096
    MAX_LISTING_BYTES = 64 * 1024 * 1024
    MAX_FRAME_BYTES = (1 << 31) - 1
    IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]{0,1023}\z/
    SECTION_NAME = /\A[\x21-\x7e]{1,1024}\z/
    UINT64 = (0..(1 << 64) - 1)
    INT64 = (-(1 << 63)..(1 << 63) - 1)

    Frame = Data.define(:bytes, :location)
    # info is sh_info: for a relocation section, the section it applies to.
    Section = Data.define(:index, :name, :type, :size, :info, :executable)
    # section is an Integer index for a defined symbol, or :undefined or
    # :special (absolute, common and reserved indices).
    ElfSymbol = Data.define(:index, :name, :value, :size, :binding, :type, :section) do
      def defined? = section.is_a?(Integer)
    end
    Relocation = Data.define(:type, :symbol, :addend)
    # relocations maps [section index, byte offset] to the one relocation
    # applied there.
    Listing = Data.define(:sections, :symbols, :relocations)
    Instruction = Data.define(:offset, :word, :mnemonic)

    module_function

    def refuse(object, message)
      raise StackGraphError, "stack graph: #{Terminal.escape(object)}: #{message}"
    end

    # One "location:name<TAB>bytes<TAB>qualifier" record per emitted
    # function. Any dynamic qualifier is refused here: the kernel has no
    # variable-length array or alloca, so a dynamic frame is a bug, and its
    # size bounds nothing.
    def stack_usage(text, object:)
      lines(text, object: object, what: 'stack-usage records').each_with_index.with_object({}) do |(line, number), frames|
        match = /\A(?<location>[^\t]+):(?<name>[^:\t]+)\t(?<bytes>\d{1,10})\t(?<qualifier>[a-z,]+)\z/.match(line)
        refuse(object, "stack-usage line #{number + 1} is not a frame record") unless match && IDENTIFIER.match?(match[:name])
        name = match[:name]
        refuse(object, "#{name}: dynamic frame (#{match[:qualifier]})") if match[:qualifier].start_with?('dynamic')
        refuse(object, "#{name}: unknown frame qualifier #{Terminal.escape(match[:qualifier])}") unless match[:qualifier] == 'static'
        bytes = Integer(match[:bytes], 10)
        refuse(object, "#{name}: frame of #{bytes} bytes exceeds the readable bound") if bytes > MAX_FRAME_BYTES
        refuse(object, "#{name}: two stack-usage records") if frames.key?(name)
        frames[name] = Frame.new(bytes: bytes, location: match[:location])
      end.freeze
    end

    # llvm-readobj --elf-output-style=JSON --file-headers --sections
    # --symbols --relocations of one AArch64 relocatable object.
    def listing(text, object:)
      document = parse_json(text, object: object)
      case document
      in [{ FileSummary: { Format: 'elf64-littleaarch64' },
            ElfHeader: { Type: 'Relocatable (0x1)', Machine: { Name: 'EM_AARCH64' } },
            Sections: Array => sections, Symbols: Array => symbols,
            Relocations: Array => relocations }]
        section_table = sections.map { |entry| section(entry, object: object) }
                                .each_with_object({}) { |entry, table| table[entry.index] = entry }.freeze
        symbol_table = symbols.each_with_index.map { |entry, index| symbol(entry, index, object: object) }.freeze
        Listing.new(sections: section_table, symbols: symbol_table,
                    relocations: relocation_table(relocations, sections: section_table, symbols: symbol_table,
                                                               object: object))
      else
        refuse(object, 'readobj listing is not one little-endian AArch64 relocatable object')
      end
    end

    # llvm-objdump -d -z: for each executable section, its instructions with
    # their section-relative offsets and raw words. Labels are read past; the
    # symbol table, not objdump's labels, decides where a function lies.
    def disassembly(text, object:)
      current = nil
      lines(text, object: object, what: 'disassembly').each_with_index.with_object({}) do |(line, number), sections|
        case line
        when '', /\A.*:\tfile format elf64-littleaarch64\z/, /\A[0-9a-f]{16} <.*>:\z/
          next
        when /\ADisassembly of section (.*):\z/
          name = Regexp.last_match(1)
          refuse(object, "disassembly line #{number + 1}: unreadable section name") unless SECTION_NAME.match?(name)
          refuse(object, "section #{name} is disassembled twice") if sections.key?(name)
          current = sections[name] = []
        when /\A *([0-9a-f]{1,16}): ([0-9a-f]{8}) +\t(\S+)(?:\t.*)?\z/
          refuse(object, "disassembly line #{number + 1}: instruction outside a section") unless current
          current << Instruction.new(offset: Integer(Regexp.last_match(1), 16), word: Integer(Regexp.last_match(2), 16),
                                     mnemonic: Regexp.last_match(3).freeze)
        else
          refuse(object, "disassembly line #{number + 1} is not an instruction, label or section heading")
        end
      end.transform_values(&:freeze).freeze
    end

    def lines(text, object:, what:)
      # Source paths may hold any bytes but control characters; every field
      # read as a name is checked against its own pattern below.
      refuse(object, "#{what} hold control characters") unless text.b.match?(/\A[^\x00-\x08\x0b-\x1f\x7f]*\z/n)
      text.split("\n").each_with_index do |line, number|
        refuse(object, "#{what} line #{number + 1} exceeds #{MAX_LINE_BYTES} bytes") if line.bytesize > MAX_LINE_BYTES
      end
    end

    # JsonInput bounds the size and depth; the keys become symbols so that
    # the listing's shape can be matched with hash patterns.
    def parse_json(text, object:)
      symbolized(JsonInput.parse(text, max_bytes: MAX_LISTING_BYTES, label: 'readobj listing'))
    rescue JsonInput::Unsupported
      raise
    rescue Error => error
      refuse(object, error.message)
    end

    def symbolized(value)
      case value
      when Hash then value.to_h { |key, member| [key.to_sym, symbolized(member)] }
      when Array then value.map { |member| symbolized(member) }
      else value
      end
    end

    def section(entry, object:)
      case entry
      in { Section: { Index: Integer => index, Name: { Name: String => name },
                          Type: { Name: String => type }, Flags: { Value: Integer => flags },
                          Size: Integer => size, Info: Integer => info } }
        refuse(object, "section #{index} has an unreadable name") unless name.empty? || SECTION_NAME.match?(name)
        unless [size, flags, info].all? { |field| UINT64.cover?(field) }
          refuse(object, "section #{name} has an out-of-range field")
        end
        Section.new(index: index, name: name.freeze, type: type.freeze, size: size, info: info,
                    executable: flags.anybits?(0x4))
      else
        refuse(object, 'readobj section entry has an unknown shape')
      end
    end

    def symbol(entry, index, object:)
      case entry
      in { Symbol: { Name: { Name: String => name }, Value: Integer => value,
                         Size: Integer => size, Binding: { Name: String => binding },
                         Type: { Name: String => type },
                         Section: { Name: String => section_name, Value: Integer => section } } }
        unless UINT64.cover?(value) && UINT64.cover?(size) && section.between?(0, 0xffff)
          refuse(object, "symbol #{index} has an out-of-range field")
        end
        ElfSymbol.new(index: index, name: name.freeze, value: value, size: size, binding: binding.freeze,
                      type: type.freeze, section: symbol_section(section, section_name))
      else
        refuse(object, 'readobj symbol entry has an unknown shape')
      end
    end

    # SHN_UNDEF is an undefined reference; every index from SHN_LORESERVE up
    # (absolute, common, extended) names no section of the object.
    def symbol_section(index, name)
      return :undefined if index.zero? && name == 'Undefined'
      return :special if index >= 0xff00

      index
    end

    def relocation_table(groups, sections:, symbols:, object:)
      groups.each_with_object({}) do |group, table|
        case group
        in { SectionIndex: Integer => rela_index, Relocs: Array => relocs }
          target = relocated_section(rela_index, sections: sections, object: object)
          relocs.each do |reloc|
            offset, relocation = relocation(reloc, symbols: symbols, object: object)
            refuse(object, "two relocations at #{target.name}+0x#{offset.to_s(16)}") if table.key?([target.index, offset])
            table[[target.index, offset].freeze] = relocation
          end
        else
          refuse(object, 'readobj relocation group has an unknown shape')
        end
      end.freeze
    end

    # A relocation group names its SHT_RELA section, whose sh_info is the
    # section it applies to. SHT_REL sections, without addends, are refused:
    # a call target is read from its addend.
    def relocated_section(rela_index, sections:, object:)
      rela = sections[rela_index]
      refuse(object, "relocation group names no section #{rela_index}") unless rela
      refuse(object, "relocation section #{rela.name} is not SHT_RELA") unless rela.type == 'SHT_RELA'
      target = sections[rela.info]
      refuse(object, "relocation section #{rela.name} applies to no section") unless target
      target
    end

    def relocation(entry, symbols:, object:)
      case entry
      in { Relocation: { Offset: Integer => offset, Type: { Name: String => type },
                             Symbol: { Name: String => name, Value: Integer => index },
                             Addend: Integer => addend } }
        symbol = symbols[index] if index.between?(1, symbols.length - 1)
        refuse(object, "relocation at 0x#{offset.to_s(16)} names no symbol") unless symbol
        # readobj prints a section symbol under its section's name in both
        # tables, so every relocation's name matches the symbol it indexes.
        unless symbol.name == name
          refuse(object, "relocation at 0x#{offset.to_s(16)} disagrees with symbol #{index}")
        end
        refuse(object, "relocation at 0x#{offset.to_s(16)} has an out-of-range field") unless UINT64.cover?(offset) && INT64.cover?(addend)
        [offset, Relocation.new(type: type.freeze, symbol: symbol, addend: addend)]
      else
        refuse(object, 'readobj relocation entry has an unknown shape')
      end
    end

    private_class_method :lines, :parse_json, :symbolized, :section, :symbol, :symbol_section, :relocation_table,
                         :relocated_section, :relocation
  end
end
