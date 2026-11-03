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
    # Host tooling reads JSON only through JsonInput, which bounds size and
    # depth and refuses duplicate keys; any other parse would bypass those.
    # Rather than list json's many ways to parse, the check allows the two
    # ways to write: outside JsonInput, the only JSON member calls a Ruby
    # source under tools/ may make are JSON.generate and JSON.pretty_generate.
    # It reads lines, not Ruby, so it is a guard against an accidental parse,
    # not against an alias of the module; a comment whose prose puts a
    # parenthesis, bracket or period right after the module's name also
    # fails it, loudly.
    JSON_PARSER = 'tools/lib/erx/json_input.rb'
    JSON_OUTSIDE_WRITING = /
      \bJSON\s*(?:
        ::                                                # a constant: Parser, Coder, ParserError
        | [(\[]                                           # the Kernel method or the index method
        | \.(?!\s*(?:generate|pretty_generate)\b)         # any other member call
      )
      | [.]from_json\b                                    # json's core additions
    /x

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
      check_json_parsing
      true
    end

    private

    def check_json_parsing
      Dir.glob('tools/**/*', base: @root).sort.each do |relative_path|
        path = File.join(@root, relative_path)
        next if relative_path == JSON_PARSER || !ruby_source?(path)
        File.binread(path).each_line.with_index(1) do |line, number|
          next unless JSON_OUTSIDE_WRITING.match?(line)
          raise Error, "JSON used other than to write, outside #{JSON_PARSER}: #{relative_path}:#{number}"
        end
      end
    end

    def ruby_source?(path)
      File.file?(path) &&
        (File.extname(path) == '.rb' || (File.binread(path, 32) || '').start_with?('#!/usr/bin/env ruby'))
    end

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
