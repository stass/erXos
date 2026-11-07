# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'hardware'

module Erx
  # hw/sysreg/aarch64.json is the checked-in system-register specification, an
  # input like an SVD file. Each register in it is erXos's access policy (the
  # POLICY_KEYS) followed by the facts Arm's machine-readable specification
  # gives for it (the FACT_KEYS), and the file names the SHA-256 of the
  # Registers.json those facts came from.
  #
  # Nothing in the build or `make check` reads Arm's archive. Only the explicit
  # `tools/erx sysreg refresh` does: it takes the policy from the checked-in
  # file, extracts the facts again from the fetched Registers.json, and either
  # rewrites the file or, with --verify, compares it (hw/sysreg/ORIGIN.md).
  module Sysreg
    SPECIFICATION = 'hw/sysreg/aarch64.json'
    SOURCE = 'build/third_party/arm-registers/Registers.json'
    MAX_SPECIFICATION_BYTES = 1024 * 1024
    MAX_SOURCE_BYTES = 128 * 1024 * 1024
    POLICY_KEYS = %w[name read write read_side_effect read_barrier].freeze
    FACT_KEYS = %w[width encoding fields copyright license source_version].freeze
    ENCODING_WIDTHS = { 'op0' => 2, 'op1' => 3, 'CRn' => 4, 'CRm' => 4, 'op2' => 3 }.freeze
    module_function

    def exact_keys(value, keys)
      unless value.is_a?(Hash) && value.keys.sort == keys.sort
        raise Error, 'unexpected system-register declaration shape'
      end
    end

    # The selection a refresh extracts: the specification's identity and each
    # register's policy, without the facts. A register may carry its policy
    # alone, which is how a new register is added before its first refresh.
    def selection(bytes)
      declaration = JsonInput.parse(bytes, max_bytes: MAX_SPECIFICATION_BYTES, label: 'system-register specification')
      exact_keys(declaration, %w[version architecture source_sha256 registers])
      unless declaration['version'].is_a?(Integer) && declaration['version'] == 1 && declaration['architecture'] == 'aarch64' &&
             declaration['source_sha256'].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(declaration['source_sha256'])
        raise Error, 'unsupported system-register source identity'
      end
      entries = declaration.fetch('registers')
      unless entries.is_a?(Array) && entries.size.between?(1, 4096)
        raise Error, 'system-register selection requires 1..4096 registers'
      end
      policies = entries.map do |entry|
        unless entry.is_a?(Hash) && [POLICY_KEYS.sort, (POLICY_KEYS + FACT_KEYS).sort].include?(entry.keys.sort)
          raise Error, 'unexpected system-register declaration shape'
        end
        Hardware.identifier(entry.fetch('name'))
        unless entry['read'] == true && entry['write'] == false &&
               entry['read_side_effect'] == 'none' && %w[none isb].include?(entry['read_barrier'])
          raise Error, 'unsupported system-register access sequence'
        end
        entry.slice(*POLICY_KEYS)
      end
      names = policies.map { |entry| entry.fetch('name').downcase }
      raise Error, 'system-register names collide' unless names.uniq == names
      immutable_copy(declaration.merge('registers' => policies))
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

    # The specification as Arm's pinned Registers.json gives it for the
    # checked-in selection, as bytes, and the checked-in bytes beside it.
    # Reads only; refuses a symlinked specification or directory.
    def refreshed(root:)
      root = File.realpath(root)
      path = File.join(root, SPECIFICATION)
      unless File.realpath(File.dirname(path)) == File.dirname(path) && File.file?(path) && !File.symlink?(path)
        raise Error, "#{SPECIFICATION} must be a regular file, not a symlink"
      end
      current = BoundedFile.read(path, maximum: MAX_SPECIFICATION_BYTES)
      declaration = selection(current)
      source = read_source(File.join(root, SOURCE))
      [JSON.pretty_generate(extract(source, declaration: declaration), ascii_only: true) + "\n", current]
    rescue SystemCallError => error
      raise Error, "cannot read #{SPECIFICATION}: #{error.message}"
    end

    def read_source(path)
      unless File.exist?(path) || File.symlink?(path)
        raise Error, "Arm's Registers.json is not fetched; run tools/erx fetch --source arm-registers first"
      end
      BoundedFile.read(path, maximum: MAX_SOURCE_BYTES)
    end
    private_class_method :read_source

    # Compares without writing: true when the checked-in specification is
    # exactly what a refresh would write.
    def verify(root:)
      expected, current = refreshed(root: root)
      raise Error, "#{SPECIFICATION} differs from Arm's pinned source; run tools/erx sysreg refresh" unless current == expected
      true
    end

    # Rewrites the specification from Arm's pinned source through a temporary
    # file renamed into place, so a failed refresh leaves the old file whole.
    # Returns whether the bytes changed.
    def refresh(root:)
      expected, current = refreshed(root: root)
      return false if current == expected

      output = File.join(File.realpath(root), SPECIFICATION)
      temporary = output + ".#{Process.pid}.tmp"
      created = false
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) do |file|
          created = true
          file.write(expected)
        end
        File.rename(temporary, output)
      ensure
        File.unlink(temporary) if created && File.file?(temporary) && !File.symlink?(temporary)
      end
      true
    rescue SystemCallError => error
      raise Error, "cannot write #{SPECIFICATION}: #{error.message}"
    end
  end
end
