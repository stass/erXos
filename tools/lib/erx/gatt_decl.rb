# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'generation_plan'

module Erx
  # The GATT service declarations (docs/design-bluetooth.md, "Declarations:
  # `abi/gatt`"): every file abi/gatt/NAME.txt, read and checked whole, becomes one
  # term of the generated Erlang module erx_gatt_decl, in the shape
  # erx_gatt_db:build/2 takes (its service() type). Nothing reads a declaration at
  # run time.
  #
  # A declaration is lines of space-separated tokens, with # starting a comment:
  #
  #   service        NAME UUID [advertise]                   once, first, NAME the file's name
  #   characteristic NAME UUID MAX ACCESS LEVEL... [value HEX]
  #
  # NAME is a lower-case identifier; UUID four lower-case hexadecimal digits, or the
  # 8-4-4-4-12 form of a 128-bit UUID in lower case; MAX the longest value in octets,
  # in decimal, at most the ABI's att_value_max; ACCESS one of ACCESSES and LEVEL one
  # of LEVELS, each access given once; HEX the initial value, two lower-case
  # hexadecimal digits an octet.
  #
  # Each UUID has one spelling: a UUID of the Bluetooth Base UUID with a 16-bit
  # value is written as those 16 bits, and its 128-bit form is refused as
  # malformed. ATT compares attribute types as 128-bit UUIDs (Core 6.3, Vol 3
  # Part F, 3.4.4.1 and 3.4.4.9, notes) but Find By Type Value compares the octets
  # of a service declaration's value (3.4.3.3), so a phone that looks for a 16-bit
  # service UUID finds only its 2-octet form. With one spelling, UUIDs are equal
  # exactly when their spellings are. (The Base UUID is Vol 3 Part B, 2.5.1, which
  # was not read; BASE_UUID is Bumble v0.0.237's, bumble/core.py, lines 202 and
  # 212, and is unverified against Part B.)
  module GattDecl
    class DeclarationError < Error; end

    DECLARATIONS = 'abi/gatt/*.txt'
    OUTPUT = 'erlang/apps/erx_bt/src/erx_gatt_decl.erl'
    MAX_DECLARATION_BYTES = 65_536
    # The enum of GATT's and GAP's own UUIDs (abi/formats/bluetooth.txt): the
    # attribute types and the two services the table lays out itself, which no
    # declaration may use.
    RESERVED_ENUM = 'gatt_uuid'
    VALUE_MAX_LIMIT = 'att_value_max'
    # The names erx_gatt_db gives GAP's and GATT's own services (gap/0, gatt/0).
    RESERVED_NAMES = %w[gap gatt].freeze
    ACCESSES = %w[read write write_without_response notify indicate].freeze
    LEVELS = %w[open encrypted authenticated bonded].freeze
    NAME = /\A[a-z][a-z0-9_]{0,62}\z/
    UUID16 = /\A[0-9a-f]{4}\z/
    UUID128 = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    DECIMAL = /\A(?:0|[1-9][0-9]{0,5})\z/
    HEX = /\A(?:[0-9a-f]{2})+\z/
    BASE_UUID = 0x0000_0000_0000_1000_8000_0080_5f9b_34fb
    # The bits of a 128-bit UUID a 16-bit UUID sets in the Base UUID.
    SHORT_BITS = 0xffff << 96
    # The 16-bit UUIDs GATT gives its attribute types, declarations from 0x2800 and
    # descriptors from 0x2900, which no service or characteristic may take: a client
    # would read a characteristic of type Include as an include. The members are Bumble
    # v0.0.237's, bumble/gatt.py, lines 130-153 (0x2800-0x2803, 0x2900-0x290f); the
    # blocks' ends at 0x28ff and 0x29ff, Assigned Numbers' allocation, are unverified.
    ATTRIBUTE_TYPES = (0x2800..0x29ff)

    # A UUID as written, 16 or 128 bits wide, and its value.
    Uuid = Data.define(:bits, :value)
    # access: ACCESSES member => LEVELS member, in ACCESSES order. value: the
    # initial value's octets, or nil.
    Characteristic = Data.define(:name, :uuid, :max, :access, :value)
    Service = Data.define(:name, :uuid, :advertise, :characteristics)
    # What a declaration is checked against, from the ABI: the reserved UUIDs =>
    # their gatt_uuid member, and the longest value.
    Vocabulary = Data.define(:reserved, :value_max)

    module_function

    # The plan Erx::Generated publishes into the build tree. It reads every
    # declaration the glob finds and every ABI source, which the vocabulary comes
    # from.
    def generation(root:)
      root = File.realpath(root)
      sources = ABI::Sources.read(root: root)
      declarations = texts(root)
      services = parse_all(declarations, ABI::Model.validate(sources))
      reads = sources.inputs.merge(declarations).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      GenerationPlan.new(files: { OUTPUT => erlang(services).freeze }, reads: reads, globs: { DECLARATIONS => declarations.keys })
    end

    # The services the declarations under root declare, each read and checked whole
    # against schema, the ABI's model, in the order of their files' paths: the names a
    # ble grant's services are drawn from (Manifest::Context#gatt_services).
    def services(root:, schema:) = parse_all(texts(root), schema)

    # Every declaration's text, by its path relative to root, in path order.
    def texts(root)
      paths = Dir.glob(DECLARATIONS, base: root).sort
      raise DeclarationError, "no GATT service declaration matches #{DECLARATIONS}" if paths.empty?

      paths.to_h { |path| [path, BoundedFile.read(File.join(root, path), maximum: MAX_DECLARATION_BYTES)] }
    end
    private_class_method :texts

    def parse_all(texts, schema)
      vocabulary = vocabulary(schema)
      texts.map { |path, text| parse(path: path, text: text, vocabulary: vocabulary) }
    end
    private_class_method :parse_all

    def vocabulary(schema)
      type = schema.types[RESERVED_ENUM]
      unless type.is_a?(ABI::EnumType) && !type.flags
        raise DeclarationError, "the ABI declares no enum #{RESERVED_ENUM}"
      end

      limit = schema.constants[VALUE_MAX_LIMIT] or raise DeclarationError, "the ABI declares no #{VALUE_MAX_LIMIT}"
      reserved = type.members.to_h { |member, value| [Uuid.new(bits: 16, value: value), member] }
      Vocabulary.new(reserved: reserved.freeze, value_max: limit.value)
    end

    # The service the file at path declares, or a DeclarationError naming the file,
    # the line and what is wrong there.
    def parse(path:, text:, vocabulary:)
      file_name = File.basename(path, '.txt')
      raise DeclarationError, "#{path}: #{file_name.inspect} is not a service name" unless file_name.match?(NAME)

      service = nil
      characteristics = []
      text.b.split("\n", -1).each.with_index(1) do |line, number|
        where = "#{path}:#{number}"
        refuse_bytes(line, where: where)
        tokens = line.partition('#').first.strip.split(/ +/)
        next if tokens.empty?

        case tokens.first
        when 'service'
          raise DeclarationError, "#{where}: a second service line" if service

          service = service_line(tokens, file_name: file_name, vocabulary: vocabulary, where: where)
        when 'characteristic'
          raise DeclarationError, "#{where}: a characteristic before the service line" unless service

          characteristic = characteristic_line(tokens, vocabulary: vocabulary, where: where)
          refuse_repeat(characteristic, characteristics, where: where)
          characteristics << characteristic
        else
          raise DeclarationError, "#{where}: #{tokens.first} is not a line of a GATT declaration"
        end
      end
      raise DeclarationError, "#{path}: no service line" unless service

      service.with(characteristics: characteristics.freeze)
    end

    # Only printable ASCII and the space reach the tokenizer: a byte above 0x7f or a
    # control byte (a tab, a carriage return) is refused, not read around.
    def refuse_bytes(line, where:)
      byte = line.each_byte.find { |candidate| candidate > 0x7e || candidate < 0x20 }
      return unless byte

      kind = byte > 0x7f ? 'a byte above 0x7f' : 'a control byte'
      raise DeclarationError, format('%s: %s, 0x%02x', where, kind, byte)
    end
    private_class_method :refuse_bytes

    def service_line(tokens, file_name:, vocabulary:, where:)
      name, uuid, advertise =
        case tokens
        in ['service', name, uuid] then [name, uuid, false]
        in ['service', name, uuid, 'advertise'] then [name, uuid, true]
        else raise DeclarationError, "#{where}: a service line is service NAME UUID [advertise]"
        end
      identifier(name, where: where)
      raise DeclarationError, "#{where}: #{name} is the name of the table's own service" if RESERVED_NAMES.include?(name)
      raise DeclarationError, "#{where}: service #{name} in a file named #{file_name}" unless name == file_name

      Service.new(name: name, uuid: parse_uuid(uuid, vocabulary: vocabulary, where: where), advertise: advertise,
                  characteristics: [].freeze)
    end
    private_class_method :service_line

    def characteristic_line(tokens, vocabulary:, where:)
      unless tokens.size >= 4
        raise DeclarationError, "#{where}: a characteristic line is characteristic NAME UUID MAX ACCESS LEVEL..."
      end

      _keyword, name, uuid, max, *rest = tokens
      identifier(name, where: where)
      # The accesses run up to the first value token (a find pattern matches the
      # leftmost), which starts the initial value.
      accesses, value = case rest
                        in [*before, 'value', *after] then [before, ['value', *after]]
                        else [rest, []]
                        end
      characteristic = Characteristic.new(name: name, uuid: parse_uuid(uuid, vocabulary: vocabulary, where: where),
                                          max: parse_max(max, vocabulary: vocabulary, where: where),
                                          access: parse_access(accesses, name: name, where: where), value: nil)
      value.empty? ? characteristic : characteristic.with(value: initial_value(value, characteristic, where: where))
    end
    private_class_method :characteristic_line

    def identifier(name, where:)
      raise DeclarationError, "#{where}: #{name} is not a name" unless name.match?(NAME)
    end
    private_class_method :identifier

    def parse_uuid(token, vocabulary:, where:)
      uuid = case token
             when UUID16 then Uuid.new(bits: 16, value: token.to_i(16))
             when UUID128 then Uuid.new(bits: 128, value: token.delete('-').to_i(16))
             else raise DeclarationError, "#{where}: #{token} is not a 16-bit or 128-bit UUID"
             end
      if uuid.bits == 128 && uuid.value & ~SHORT_BITS == BASE_UUID
        raise DeclarationError, format('%s: %s is written %04x, in 16 bits', where, token, uuid.value >> 96)
      end
      member = vocabulary.reserved[uuid]
      raise DeclarationError, "#{where}: #{token} is GATT's or GAP's own UUID #{member}" if member
      if uuid.bits == 16 && ATTRIBUTE_TYPES.cover?(uuid.value)
        raise DeclarationError, "#{where}: #{token} is a GATT attribute type"
      end

      uuid
    end
    private_class_method :parse_uuid

    def parse_max(token, vocabulary:, where:)
      raise DeclarationError, "#{where}: #{token} is not a length in decimal" unless token.match?(DECIMAL)

      max = token.to_i
      raise DeclarationError, "#{where}: a maximum of #{max}, over #{vocabulary.value_max}" if max > vocabulary.value_max

      max
    end
    private_class_method :parse_max

    # The accesses and their levels, in pairs; an access followed by another access,
    # by value or by nothing has no level. The result is in ACCESSES order, so the
    # generated module does not depend on the order a line gives them in.
    def parse_access(tokens, name:, where:)
      levels = tokens.each_slice(2).each_with_object({}) do |(access, level), map|
        raise DeclarationError, "#{where}: #{access} is not an access" unless ACCESSES.include?(access)
        raise DeclarationError, "#{where}: #{access} given twice" if map.key?(access)
        raise DeclarationError, "#{where}: #{access} has no level" if level.nil? || ACCESSES.include?(level)
        raise DeclarationError, "#{where}: #{level} is not a level" unless LEVELS.include?(level)

        map[access] = level
      end
      raise DeclarationError, "#{where}: #{name} allows no access" if levels.empty?
      if levels.key?('notify') && levels.key?('indicate') && levels['notify'] != levels['indicate']
        raise DeclarationError, "#{where}: #{name} notifies #{levels['notify']} and indicates #{levels['indicate']}"
      end

      levels.sort_by { |access, _level| ACCESSES.index(access) }.to_h.freeze
    end
    private_class_method :parse_access

    def initial_value(tokens, characteristic, where:)
      hex = case tokens
            in ['value', hex] if hex.match?(HEX) then hex
            else raise DeclarationError, "#{where}: value takes one string of lower-case hexadecimal octets"
            end
      octets = [hex].pack('H*')
      unless characteristic.access.key?('read')
        raise DeclarationError, "#{where}: an initial value of #{characteristic.name}, which is not readable"
      end
      if octets.bytesize > characteristic.max
        raise DeclarationError,
              "#{where}: an initial value of #{octets.bytesize} octets, over #{characteristic.name}'s maximum"
      end

      octets.freeze
    end
    private_class_method :initial_value

    def refuse_repeat(characteristic, earlier, where:)
      if earlier.any? { |other| other.name == characteristic.name }
        raise DeclarationError, "#{where}: a second characteristic #{characteristic.name}"
      end
      return unless (other = earlier.find { |candidate| candidate.uuid == characteristic.uuid })

      raise DeclarationError, "#{where}: #{characteristic.name} has #{other.name}'s UUID"
    end
    private_class_method :refuse_repeat

    # erx_gatt_decl: names/0, advertised/0 and service/1, one clause per service in
    # the order of its name. Every atom is quoted, so a name that is a reserved word
    # (end, of) is an atom all the same.
    def erlang(services)
      names = services.map { |service| atom(service.name) }
      advertised = services.select(&:advertise).map { |service| atom(service.name) }
      <<~ERLANG
        %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
        %% SPDX-License-Identifier: BSD-2-Clause
        %% Generated by tools/lib/erx/gatt_decl.rb (tools/gen_gatt.rb) from #{DECLARATIONS}; do not edit.
        -module(erx_gatt_decl).
        -moduledoc """
        The GATT services declared in abi/gatt (docs/design-bluetooth.md, "Declarations:
        `abi/gatt`"), each as erx_gatt_db:build/2 takes it: UUIDs as ATT carries them, least
        significant octet first, and each access with the level it requires.
        """.

        -export([names/0, advertised/0, service/1]).
        -export_type([name/0]).

        -type name() :: #{names.join(' | ')}.

        -doc "Every declared service.".
        -spec names() -> [name(), ...].
        names() ->
            [#{names.join(', ')}].

        -doc "The declared services whose declarations say `advertise`, served or not.".
        -spec advertised() -> [name()].
        advertised() ->
            [#{advertised.join(', ')}].

        -doc "The declaration of the service `Name`.".
        -spec service(name()) -> erx_gatt_db:service().
        #{services.map { |service| service_clause(service) }.join(";\n")}.
      ERLANG
    end
    private_class_method :erlang

    def service_clause(service)
      characteristics = service.characteristics.map { |characteristic| characteristic_term(characteristic) }
      list = characteristics.empty? ? ' []' : "\n          [#{characteristics.join(",\n           ")}]"
      "service(#{atom(service.name)}) ->\n    " \
        "\#{name => #{atom(service.name)}, uuid => #{uuid_literal(service.uuid)},\n      " \
        "characteristics =>#{list}}"
    end
    private_class_method :service_clause

    def characteristic_term(characteristic)
      access = characteristic.access.map { |key, level| "#{key} => #{level}" }.join(', ')
      value = characteristic.value && ",\n             value => #{binary_literal(characteristic.value)}"
      "\#{name => #{atom(characteristic.name)}, uuid => #{uuid_literal(characteristic.uuid)}, " \
        "max => #{characteristic.max},\n             access => \#{#{access}}#{value}}"
    end
    private_class_method :characteristic_term

    def atom(name) = "'#{name}'"
    private_class_method :atom

    # The UUID's value in hexadecimal as it is written, stored least significant
    # octet first (Vol 3 Part F, 3.3.1).
    def uuid_literal(uuid)
      format("<<16#%0#{uuid.bits / 4}x:#{uuid.bits}/little>>", uuid.value)
    end
    private_class_method :uuid_literal

    def binary_literal(octets)
      lines = octets.bytes.each_slice(12).map { |slice| slice.map { |byte| format('16#%02x', byte) }.join(', ') }
      "<<#{lines.join(",\n                        ")}>>"
    end
    private_class_method :binary_literal
  end
end
