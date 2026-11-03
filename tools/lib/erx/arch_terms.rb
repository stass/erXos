# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'runner'
require_relative 'source_text'
require_relative 'bounded_file'

module Erx
  module ArchTerms
    GENERIC_ROOTS = %w[kernel include/erx liberx runtime system].freeze
    BINDING_ROOTS = %w[kernel/arch/ kernel/platform/ include/erx/arch/ include/erx/hw/
                       liberx/arch/ runtime/arch/ system/arch/].freeze
    module_function

    def parse(bytes)
      unless bytes.is_a?(String) && bytes.bytesize <= 64 * 1024 && bytes.ascii_only?
        raise Error, 'architecture term policy must be bounded ASCII'
      end
      entries = bytes.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
      raise Error, 'architecture term policy requires 1..4096 unique entries' unless entries.size.between?(1, 4096) && entries.uniq == entries
      patterns = entries.map do |entry|
        match = /\A(word|prefix) ([A-Za-z][A-Za-z0-9_-]{0,127})\z/.match(entry)
        raise Error, 'invalid architecture term policy entry' unless match
        left = '(?<![A-Za-z0-9])'
        right = match[1] == 'word' ? '(?![A-Za-z0-9])' : ''
        Regexp.new(left + Regexp.escape(match[2]) + right, Regexp::IGNORECASE)
      end
      Regexp.union(patterns).freeze
    end

    def binding_path?(relative)
      BINDING_ROOTS.any? { |prefix| relative.start_with?(prefix) } ||
        relative.match?(/\Aliberx\/backend\/[^\/]+\/arch\//)
    end

    def inputs(root:)
      sources = GENERIC_ROOTS.flat_map do |directory|
        Dir.glob(File.join(root, directory, '**/*')).select do |path|
          relative = path.delete_prefix(root + '/')
          !binding_path?(relative) && File.file?(path) && SourceText.source?(relative, bytes: ''.b)
        end
      end
      documents = Dir.glob(File.join(root, 'docs/design*.md')).reject do |path|
        File.basename(path).start_with?('design-arch-') || File.basename(path) == 'design-platforms.md'
      end
      (sources + documents).sort
    end

    def check(root:)
      root = File.expand_path(root)
      declarations = Dir.glob(File.join(root, 'hw/arch_terms/*.txt')).sort
      raise Error, 'no architecture term policies found' if declarations.empty?
      pattern = Regexp.union(declarations.map { |path| parse(BoundedFile.read(path, maximum: 64 * 1024)) })
      violations = inputs(root: root).flat_map do |path|
        bytes = BoundedFile.read(path, maximum: 32 * 1024 * 1024).dup.force_encoding(Encoding::UTF_8)
        raise Error, 'generic source is not UTF-8' unless bytes.valid_encoding?
        bytes.lines.each_with_index.map do |line, index|
          match = pattern.match(line)
          "#{path.delete_prefix(root + '/')}:#{index + 1}: #{match[0]}" if match
        end.compact
      end
      raise Error, "architecture terms outside binding layers:\n#{violations.join("\n")}" unless violations.empty?
      true
    rescue SystemCallError => error
      raise Error, "cannot check architecture terms: #{error.message}"
    end
  end
end
