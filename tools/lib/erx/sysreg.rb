# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'hardware'

module Erx
  module Sysreg
    MAX_SOURCE_BYTES = 128 * 1024 * 1024
    ENCODING_WIDTHS = { 'op0' => 2, 'op1' => 3, 'CRn' => 4, 'CRm' => 4, 'op2' => 3 }.freeze
    module_function

    def exact_keys(value, keys)
      unless value.is_a?(Hash) && value.keys.sort == keys.sort
        raise Error, 'unexpected system-register declaration shape'
      end
    end

    def policy(bytes)
      declaration = JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'system-register policy')
      exact_keys(declaration, %w[version architecture source_sha256 registers])
      unless declaration['version'].is_a?(Integer) && declaration['version'] == 1 && declaration['architecture'] == 'aarch64' &&
             declaration['source_sha256'].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(declaration['source_sha256'])
        raise Error, 'unsupported system-register source identity'
      end
      entries = declaration.fetch('registers')
      unless entries.is_a?(Array) && entries.size.between?(1, 4096)
        raise Error, 'system-register selection requires 1..4096 registers'
      end
      names = entries.map do |entry|
        exact_keys(entry, %w[name read write read_side_effect read_barrier])
        name = Hardware.identifier(entry.fetch('name'))
        unless entry['read'] == true && entry['write'] == false &&
               entry['read_side_effect'] == 'none' && %w[none isb].include?(entry['read_barrier'])
          raise Error, 'unsupported system-register access sequence'
        end
        name.downcase
      end
      raise Error, 'system-register names collide' unless names.uniq == names
      immutable_copy(declaration)
    end

    # The extractor reads facts, not the package's access pseudocode. erXos's
    # explicit policy owns the permitted operation and its synchronization.
    # A feature-dependent field layout cannot be selected implicitly.
    def extract(bytes, declaration:)
      unless Digest::SHA256.hexdigest(bytes) == declaration.fetch('source_sha256')
        raise Error, 'Arm Registers.json differs from its pinned source'
      end
      source = JsonInput.parse(bytes, max_bytes: MAX_SOURCE_BYTES, label: 'Arm register source')
      unless source.is_a?(Array) && source.size.between?(1, 65_536)
        raise Error, 'Arm register source requires 1..65536 records'
      end
      selected = declaration.fetch('registers').map { |entry| entry.fetch('name') }.to_h { |name| [name, true] }
      index = source.each_with_object({}) do |row, result|
        next unless row.is_a?(Hash) && row['_type'] == 'Register' && row['state'] == 'AArch64' && selected.key?(row['name'])
        raise Error, 'ambiguous Arm register name' if result.key?(row['name'])
        result[row.fetch('name')] = row
      end
      registers = declaration.fetch('registers').map do |entry|
        record = index.fetch(entry.fetch('name')) { raise Error, "missing Arm register: #{entry.fetch('name')}" }
        extract_register(record, entry: entry)
      end
      immutable_copy('version' => 1, 'architecture' => declaration.fetch('architecture'),
        'source_sha256' => declaration.fetch('source_sha256'),
        'registers' => registers.sort_by { |register| register.fetch('name') })
    rescue KeyError => error
      raise Error, "unsupported Arm register record: #{error.message}"
    end

    def extract_register(record, entry:)
      metadata = record.fetch('_meta')
      raise Error, 'invalid Arm source metadata' unless metadata.is_a?(Hash)
      license = metadata.fetch('license')
      version = metadata.fetch('version')
      unless license.is_a?(Hash) && license['copyright'].is_a?(String) &&
             license['info'].is_a?(String) && license['info'].include?('BSD 3-clause') &&
             version.is_a?(Hash) && version['schema'] == '2.9.6'
        raise Error, 'Arm register has unsupported source provenance'
      end
      layouts = record.fetch('fieldsets')
      unless layouts.is_a?(Array) && layouts.size == 1 &&
             layouts.first.is_a?(Hash) &&
             layouts.first['condition'] == { '_type' => 'AST.Bool', 'value' => true } &&
             layouts.first['width'].is_a?(Integer) && layouts.first['width'] == 64
        raise Error, 'conditional or ambiguous Arm register layout is unsupported'
      end
      fields = extract_fields(layouts.first.fetch('values'))
      all_accessors = record.fetch('accessors')
      unless all_accessors.is_a?(Array) && all_accessors.size.between?(1, 16) && all_accessors.all? { |accessor| accessor.is_a?(Hash) }
        raise Error, 'invalid Arm accessor inventory'
      end
      accessors = all_accessors.select { |accessor| accessor['name'] == 'A64.MRS' }
      unless accessors.size == 1 && accessors.first['encoding'].is_a?(Array) && accessors.first.fetch('encoding').size == 1
        raise Error, 'missing or ambiguous Arm read encoding'
      end
      encoding = accessors.first.fetch('encoding').first
      exact_keys(encoding, %w[_type asmvalue encodings])
      unless encoding.is_a?(Hash) && encoding['_type'] == 'Encoding' && encoding['asmvalue'] == entry.fetch('name')
        raise Error, 'Arm accessor names a different register'
      end
      bits = encoding.fetch('encodings')
      exact_keys(bits, ENCODING_WIDTHS.keys)
      numbers = ENCODING_WIDTHS.map do |name, width|
        component = bits.fetch(name)
        raise Error, 'invalid Arm encoding component' unless component.is_a?(Hash)
        value = component.fetch('value')
        unless value.is_a?(String) && /\A'[01]{#{width}}'\z/.match?(value)
          raise Error, 'Arm register encoding is not a fixed bit string'
        end
        [name, value[1, width].to_i(2)]
      end.to_h
      entry.merge('width' => 64, 'encoding' => numbers, 'fields' => fields,
                  'copyright' => license.fetch('copyright'), 'license' => 'BSD-3-Clause',
                  'source_version' => metadata.fetch('version'))
    end

    def extract_fields(entries)
      raise Error, 'invalid Arm field inventory' unless entries.is_a?(Array) && entries.size.between?(1, 64)
      occupied = 0
      fields = entries.map do |entry|
        raise Error, 'invalid Arm field' unless entry.is_a?(Hash)
        allowed = case entry['_type']
                  when 'Fields.Field' then %w[_type access description display name rangeset resets values volatile]
                  when 'Fields.Reserved' then %w[_type description rangeset value]
                  else []
                  end
        raise Error, 'unsupported Arm field attributes' unless (entry.keys - allowed).empty?
        ranges = entry.fetch('rangeset')
        unless ranges.is_a?(Array) && ranges.size == 1 && ranges.first.is_a?(Hash) && ranges.first['_type'] == 'Range'
          raise Error, 'split Arm fields are unsupported'
        end
        offset = ranges.first.fetch('start')
        width = ranges.first.fetch('width')
        exact_keys(ranges.first, %w[_type start width])
        unless offset.is_a?(Integer) && width.is_a?(Integer) && offset >= 0 && width.positive? && width <= 64 && offset <= 64 - width
          raise Error, 'Arm field exceeds its register'
        end
        mask = ((1 << width) - 1) << offset
        raise Error, 'Arm fields overlap' unless (occupied & mask).zero?
        occupied |= mask
        case entry.fetch('_type')
        when 'Fields.Field'
          values = entry.fetch('values')
          unless entry['access'].nil? && values == { '_type' => 'Valuesets.Values', 'values' => [] }
            raise Error, 'Arm field overrides or enumerations require support'
          end
          { 'name' => Hardware.identifier(entry.fetch('name')), 'offset' => offset, 'width' => width }
        when 'Fields.Reserved'
          raise Error, 'unsupported Arm reserved-bit semantics' unless %w[RES0 RES1].include?(entry['value'])
          { 'reserved' => entry.fetch('value'), 'offset' => offset, 'width' => width }
        else
          raise Error, 'unsupported Arm field kind'
        end
      end
      raise Error, 'Arm field inventory leaves undeclared bits' unless occupied == (1 << 64) - 1
      names = fields.select { |field| field.key?('name') }.map { |field| field.fetch('name').downcase }
      raise Error, 'Arm field names collide' unless names.uniq == names
      fields.sort_by { |field| field.fetch('offset') }
    end

    # JsonInput caps depth before either projection reaches this copy. Copying
    # strings also keeps freezing the result from mutating the caller's values.
    def immutable_copy(value)
      case value
      when Hash
        value.to_h { |key, member| [key.dup.freeze, immutable_copy(member)] }.freeze
      when Array
        value.map { |member| immutable_copy(member) }.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end
    private_class_method :immutable_copy

    def extract_file(source:, policy_path:)
      declaration = policy(BoundedFile.read(policy_path, maximum: 1024 * 1024))
      bytes = BoundedFile.read(source, maximum: MAX_SOURCE_BYTES)
      JSON.pretty_generate(extract(bytes, declaration: declaration), ascii_only: true) + "\n"
    rescue SystemCallError => error
      raise Error, "cannot extract Arm registers; run make fetch first: #{error.message}"
    end

    def plan(root:)
      root = File.realpath(root)
      directory = File.join(root, 'hw/sysreg')
      raise Error, 'system-register output directory must not be a symlink' unless File.realpath(directory) == directory
      expected = %w[aarch64-policy.json aarch64.json].map { |name| File.join(directory, name) }
      unless (Dir.glob(File.join(directory, '*.json')) - expected).empty?
        raise Error, 'orphaned or unsupported system-register declaration/output'
      end
      bytes = extract_file(source: File.join(root, 'build/third_party/arm-registers/Registers.json'),
                           policy_path: File.join(directory, 'aarch64-policy.json'))
      { 'hw/sysreg/aarch64.json' => bytes.freeze }.freeze
    rescue SystemCallError => error
      raise Error, "cannot plan system-register extraction: #{error.message}"
    end

    def check_outputs(plan, root:)
      plan.each do |relative, bytes|
        path = File.join(root, relative)
        unless File.file?(path) && !File.symlink?(path) && BoundedFile.read(path, maximum: bytes.bytesize) == bytes
          raise Error, "system-register extraction drift: #{relative}"
        end
      end
      true
    rescue SystemCallError => error
      raise Error, "cannot check system-register extraction: #{error.message}"
    end

    def check(root:)
      check_outputs(plan(root: root), root: File.realpath(root))
    end
  end
end
