# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'runner'
require_relative 'json_input'
require_relative 'source_text'
require_relative 'bounded_file'

module Erx
  # Import inventories record attribution decisions; they do not infer a
  # licence merely because a file has no notice. Defaults require review.
  module Attribution
    module_function

    def validate_expression(expression)
      unless expression.is_a?(String) && expression.ascii_only? && expression.bytesize.between?(1, 1024)
        raise Error, 'invalid source licence expression'
      end
      tokens = expression.scan(/[A-Za-z0-9][A-Za-z0-9.+_:\-]*|[()]/)
      unless tokens.join == expression.gsub(/[ \t]/, '')
        raise Error, 'invalid source licence tokens'
      end
      depth = 0
      needs_operand = true
      needs_exception = false
      can_take_exception = false
      tokens.each do |token|
        case token
        when '('
          raise Error, 'invalid licence grouping' unless needs_operand && !needs_exception && depth < 32
          depth += 1
        when ')'
          raise Error, 'invalid licence grouping' if needs_operand || depth.zero?
          depth -= 1
          can_take_exception = false
        when 'AND', 'OR'
          raise Error, 'missing licence operand' if needs_operand
          needs_operand = true
          can_take_exception = false
        when 'WITH'
          raise Error, 'invalid licence exception' unless !needs_operand && can_take_exception
          needs_operand = true
          needs_exception = true
          can_take_exception = false
        else
          raise Error, 'missing licence operator' unless needs_operand
          raise Error, 'unresolved source licence' if %w[NOASSERTION NONE].include?(token)
          needs_operand = false
          can_take_exception = !needs_exception
          needs_exception = false
        end
      end
      raise Error, 'incomplete licence expression' if needs_operand || !depth.zero?
      expression
    end

    # Corrections require an exact upstream declaration. Otherwise actual
    # notices take precedence, followed by the first matching reviewed rule.
    def for_file(path, bytes:, sidecar:, review:)
      explicit = spdx(bytes)
      correction = review.fetch('rules').find do |rule|
        rule['declared_license'] && rule.fetch('declared_license') == explicit &&
          File.fnmatch?(rule.fetch('pattern'), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
      if correction
        validate_expression(correction.fetch('license'))
        return { 'license' => correction.fetch('license'),
                 'evidence' => correction.fetch('evidence'), 'reviewed' => true }
      end
      if explicit
        validate_expression(explicit)
        return { 'license' => explicit, 'evidence' => 'file SPDX', 'reviewed' => false }
      end

      attached = spdx(sidecar)
      if attached
        validate_expression(attached)
        return { 'license' => attached, 'evidence' => "#{path}.license", 'reviewed' => false }
      end

      rule = review.fetch('rules').find do |candidate|
        !candidate.key?('declared_license') &&
          File.fnmatch?(candidate.fetch('pattern'), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
      if rule
        return { 'license' => rule.fetch('license'),
                 'evidence' => rule.fetch('evidence'), 'reviewed' => true }
      end
      { 'license' => review.fetch('default_license'),
        'evidence' => review.fetch('default_evidence'), 'reviewed' => true }
    end

    def spdx(bytes)
      return nil if bytes.nil? || bytes.include?("\0")

      match = bytes.match(/^[ \t]*(?:(?:[#%*;\/]+|--)[ \t]*)?SPDX-License-Identifier:[ \t]*([^\r\n]+)/n)
      return nil unless match

      expression = match[1].sub(/[ \t]*(?:\*\/|-->).*\z/n, '').strip
      expression
    end
    private_class_method :spdx
  end

  class Origin
    INVENTORY_MARKER = "\n```json\n"
    PAYLOAD_FIELDS = %w[version repository revision archive_sha256 exclusions files changes].freeze

    def initialize(root:, read_bytes: nil, authorize: nil, known_hash: nil)
      @root = File.expand_path(root)
      @read_bytes = read_bytes
      @authorize = authorize
      @known_hash = known_hash
    end

    def write(repository:, revision:, archive_sha256:, review:, exclusions: [])
      output = File.join(@root, 'ORIGIN.md')
      raise Error, "origin already exists: #{output}" if File.exist?(output) || File.symlink?(output)
      raise Error, 'invalid import SHA-256' unless /\A[0-9a-f]{64}\z/.match?(archive_sha256)

      inventory = files.to_h do |path|
        [path, inventory_entry(path, review: review)]
      end
      payload = { 'version' => 1, 'repository' => repository, 'revision' => revision,
                  'archive_sha256' => archive_sha256, 'exclusions' => exclusions,
                  'files' => inventory, 'changes' => {} }
      validate_inventory(payload)
      text = "# Source origin\n\nRepository: #{repository}\n\nRevision: #{revision}\n\n" \
             "The inventory records the imported bytes and their licence evidence.\n" \
             "Third-party notices remain in their original files.\n"
      File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.write(text + INVENTORY_MARKER + JSON.pretty_generate(payload) + "\n```\n")
      end
    end

    def check
      payload = read
      original = payload.fetch('files')
      current = files
      required = original.keys | payload.fetch('changes').keys
      missing = required - current
      raise Error, "imported source file is missing: #{missing.first}" unless missing.empty?
      current.each do |path|
        absolute = File.join(@root, path)
        @authorize.call(absolute) if @authorize
        baseline = original[path]
        if File.symlink?(absolute)
          validate_link(absolute)
          hash = Digest::SHA256.hexdigest("symlink\0" + File.readlink(absolute))
          unless baseline && baseline.fetch('kind') == 'symlink' && baseline.fetch('sha256') == hash
            raise Error, "changed imported link requires an explicit origin entry: #{path}"
          end
          next
        end
        if baseline && baseline.fetch('kind') != 'file'
          raise Error, "imported file type differs from its source record: #{path}"
        end
        # Only an immutable input-tree owner supplies this callback, after its
        # complete byte/path verification. Unchanged files need no second read;
        # modified files still pass the ordinary notice and ASCII checks below.
        if baseline && @known_hash && @known_hash.call(absolute) == baseline.fetch('sha256')
          next
        end
        bytes = read_content(absolute)
        if baseline && baseline.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
          next
        end
        notice = baseline ? 'Modified by erXos' : 'SPDX-License-Identifier: BSD-2-Clause'
        explicit_change = payload.fetch('changes')[path]
        if !source?(path, bytes: bytes) && explicit_change &&
           explicit_change.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
          next
        end
        unless header_notice?(bytes, notice: notice)
          raise Error, "imported file lacks its erXos change notice: #{path}"
        end
        next unless source?(path, bytes: bytes)

        permitted = baseline ? baseline.fetch('non_ascii_lines', []).dup : []
        bytes.lines.reject(&:ascii_only?).each do |line|
          hash = Digest::SHA256.hexdigest(line)
          index = permitted.index(hash)
          raise Error, "non-ASCII erXos addition to imported source: #{path}" unless index
          permitted.delete_at(index)
        end
      end
      payload
    end

    def inventory
      read
    end

    # The inventory's row for a file as imported; nil for a file it does not list.
    def imported_file(path) = read.fetch('files')[path]

    private

    def inventory_entry(path, review:)
      absolute = File.join(@root, path)
      if File.symlink?(absolute)
        validate_link(absolute)
        target = File.readlink(absolute)
        attribution = Attribution.for_file(path, bytes: ''.b, sidecar: nil, review: review)
        return attribution.merge('sha256' => Digest::SHA256.hexdigest("symlink\0" + target),
                                 'kind' => 'symlink', 'target' => target)
      end

      bytes = read_content(absolute)
      sidecar = "#{absolute}.license"
      attribution = Attribution.for_file(path, bytes: bytes,
                                         sidecar: File.file?(sidecar) ? read_content(sidecar) : nil,
                                         review: review)
      non_ascii = source?(path, bytes: bytes) ? bytes.lines.reject(&:ascii_only?).map { |line| Digest::SHA256.hexdigest(line) } : []
      attribution.merge('sha256' => Digest::SHA256.hexdigest(bytes),
                        'kind' => 'file', 'non_ascii_lines' => non_ascii)
    end

    def validate_link(path)
      root = File.realpath(@root)
      resolved = File.realpath(path)
      unless resolved == root || resolved.start_with?(root + '/')
        raise Error, "import link escapes its source tree: #{path}"
      end
    rescue Errno::ENOENT, Errno::ELOOP => error
      raise Error, "unresolved import link: #{error.message}"
    end

    def header_notice?(bytes, notice:)
      bytes.byteslice(0, 8192).lines.each do |line|
        stripped = line.lstrip
        next if stripped.strip.empty?
        return false unless stripped.start_with?('#', '%', ';', '//', '/*', '*', '<!--', '--')
        comment = stripped.split('*/', 2).first.split('-->', 2).first
        return true if comment.include?(notice)
      end
      false
    end

    def source?(path, bytes:)
      SourceText.source?(path, bytes: bytes)
    end

    def files
      Dir.glob(File.join(@root, '**/*'), File::FNM_DOTMATCH).each_with_object([]) do |path, selected|
        next if ['.', '..'].include?(File.basename(path))
        next unless File.file?(path) || File.symlink?(path)
        relative = path.delete_prefix(@root + '/')
        next if relative == 'ORIGIN.md'
        selected << relative
      end.sort
    end

    def read
      path = File.join(@root, 'ORIGIN.md')
      raise Error, 'source origin record must not be a symbolic link' if File.symlink?(path)
      bytes = read_content(path, maximum: 64 * 1024 * 1024 + 65_536)
      _prose, marker, tail = bytes.partition(INVENTORY_MARKER)
      raise Error, 'origin inventory is missing' if marker.empty?
      data, ending, rest = tail.partition("\n```\n")
      raise Error, 'origin inventory framing is invalid' if ending.empty? || !rest.empty?
      payload = JsonInput.parse(data, max_bytes: 64 * 1024 * 1024, label: 'origin inventory')
      validate_inventory(payload)
      payload
    rescue KeyError => error
      raise Error, "invalid origin inventory: #{error.message}"
    end

    def validate_inventory(payload)
      unless payload.is_a?(Hash) && payload.keys.sort == PAYLOAD_FIELDS.sort &&
             payload.fetch('version') == 1 && payload.fetch('files').is_a?(Hash) &&
             payload.fetch('changes').is_a?(Hash) && payload.fetch('exclusions').is_a?(Array)
        raise Error, 'invalid origin inventory fields'
      end
      %w[repository revision].each { |field| validate_text(payload.fetch(field)) }
      validate_hash(payload.fetch('archive_sha256'))
      payload.fetch('exclusions').each do |exclusion|
        unless exclusion.is_a?(Hash) && exclusion.keys.sort == %w[path reason]
          raise Error, 'invalid import exclusion'
        end
        validate_path(exclusion.fetch('path'))
        validate_text(exclusion.fetch('reason'))
      end
      payload.fetch('files').each { |path, entry| validate_entry(path, entry: entry) }
      payload.fetch('changes').each do |path, change|
        validate_path(path)
        unless change.is_a?(Hash) && change.keys.sort == %w[evidence license sha256]
          raise Error, 'invalid explicit import change'
        end
        Attribution.validate_expression(change.fetch('license'))
        validate_text(change.fetch('evidence'))
        validate_hash(change.fetch('sha256'))
      end
    end

    def read_content(path, maximum: nil)
      @authorize.call(path) if @authorize
      return @read_bytes.call(path) if @read_bytes
      maximum ? BoundedFile.read(path, maximum: maximum) : File.binread(path)
    end

    def validate_entry(path, entry:)
      validate_path(path)
      raise Error, 'invalid origin file entry' unless entry.is_a?(Hash)
      common = %w[license evidence reviewed sha256 kind]
      case entry['kind']
      when 'file'
        expected = common + %w[non_ascii_lines]
        lines = entry['non_ascii_lines']
        raise Error, 'invalid original source line hashes' unless lines.is_a?(Array)
        lines.each { |hash| validate_hash(hash) }
      when 'symlink'
        expected = common + %w[target]
        validate_text(entry['target'])
      else
        raise Error, 'invalid origin file kind'
      end
      raise Error, 'invalid origin entry fields' unless entry.keys.sort == expected.sort
      Attribution.validate_expression(entry.fetch('license'))
      validate_text(entry.fetch('evidence'))
      validate_hash(entry.fetch('sha256'))
      unless [true, false].include?(entry.fetch('reviewed'))
        raise Error, 'invalid origin review marker'
      end
    end

    def validate_path(path)
      validate_text(path)
      if path.start_with?('/') || path.split('/', -1).any? { |part| ['', '.', '..'].include?(part) }
        raise Error, 'invalid origin-relative path'
      end
    end

    def validate_text(value)
      unless value.is_a?(String) && value.valid_encoding? && !value.empty? && !value.match?(/[\x00-\x1f\x7f]/)
        raise Error, 'invalid origin text'
      end
    end

    def validate_hash(value)
      raise Error, 'invalid origin SHA-256' unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
    end
  end
end
