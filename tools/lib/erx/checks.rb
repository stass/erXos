# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'origin'
require_relative 'source_text'

module Erx
  class Checks
    IMPORTS = %w[otp musl fiasco/kernel fiasco/mk fiasco/l4re-core fiasco/bootstrap
                 fiasco/libfdt fiasco/drivers-frst test/oracle/common_test].freeze
    PRIVATE_DIRECTORIES = %w[.git .codex .agents .aws build].freeze

    def initialize(root:, required_imports: IMPORTS)
      @root = File.expand_path(root)
      @required_imports = required_imports
    end

    def run
      imports = @required_imports.map do |relative|
        path = File.join(@root, relative)
        marker = File.join(path, 'ORIGIN.md')
        unless File.directory?(path) && File.file?(marker) && !File.symlink?(path) && !File.symlink?(marker)
          raise Error, "missing imported source provenance: #{relative}/ORIGIN.md"
        end
        Origin.new(root: path).check
        path
      end
      check_own_sources(imports: imports)
      true
    end

    private

    def check_own_sources(imports:)
      pending = [@root]
      until pending.empty?
        directory = pending.pop
        Dir.each_child(directory) do |name|
          next if directory == @root && PRIVATE_DIRECTORIES.include?(name)
          path = File.join(directory, name)
          next if imports.include?(path)
          stat = File.lstat(path)
          if stat.symlink?
            resolved = File.realpath(path)
            unless resolved.start_with?(@root + '/')
              raise Error, "source link leaves the project: #{relative(path)}"
            end
            if File.directory?(path)
              raise Error, "own source directory aliases are unsupported: #{relative(path)}"
            end
            check_ascii(path)
          elsif stat.directory?
            pending << path
          elsif stat.file?
            check_ascii(path)
          else
            raise Error, "special file in source tree: #{relative(path)}"
          end
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP => error
      raise Error, "unresolved source link: #{error.message}"
    end

    def check_ascii(path)
      return if File.extname(path) == '.md'
      prefix = File.binread(path, 2) || ''.b
      return unless SourceText.source?(relative(path), bytes: prefix)
      bytes = File.binread(path)
      return if bytes.ascii_only?
      line = bytes.lines.each_with_index.find { |text, _index| !text.ascii_only? }.last + 1
      raise Error, "non-ASCII erXos source: #{relative(path)}:#{line}"
    end

    def relative(path)
      path.delete_prefix(@root + '/')
    end
  end
end
