# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require_relative 'error'
require_relative 'runtime'

module Erx
  # `make check-runtime-seam`'s name check (docs/design-runtime.md, "What ERTS
  # imports"): ERTS's objects import from outside themselves only liberx's calls
  # and the names in sys/erxos/imports.txt.
  module RuntimeSeam
    Violation = Data.define(:object, :name)
    Report = Data.define(:violations, :unused)
    IMPORTS_FILE = 'erts/emulator/sys/erxos/imports.txt'
    NAME = /\A[A-Za-z_][A-Za-z0-9_$.]*\z/
    # The libraries the emulator links beside its own objects, under erts/.
    LIBRARIES = %W[
      emulator/pcre/obj/#{Runtime::TARGET}/opt/libepcre.a emulator/ryu/obj/#{Runtime::TARGET}/opt/libryu.a
      emulator/zlib/obj/#{Runtime::TARGET}/opt/libz.a emulator/zstd/obj/#{Runtime::TARGET}/opt/libzstd.a
      lib/internal/#{Runtime::TARGET}/libethread.a lib/internal/#{Runtime::TARGET}/liberts_internal_r.a
    ].freeze

    module_function

    # A list holds names separated by white space; `#` starts a comment and
    # `[section]` opens a group a package can drop as a whole.
    def parse_imports(text)
      section = nil
      text.each_line(chomp: true).with_index(1).each_with_object({}) do |(line, number), sections|
        entry = line.sub(/#.*/, '').strip
        next if entry.empty?

        if (opened = entry[/\A\[([a-z0-9_-]+)\]\z/, 1])
          raise Error, "imports line #{number}: section #{opened} opened twice" if sections.key?(opened)

          section = opened
          sections[section] = []
        else
          raise Error, "imports line #{number}: a name before any section" if section.nil?

          entry.split.each do |name|
            raise Error, "imports line #{number}: not a name: #{name}" unless NAME.match?(name)

            sections.fetch(section) << name
          end
        end
      end.freeze
    end

    # The C names in nm's output, without its file headers. Mach-O prefixes each
    # C name with one underscore.
    def symbol_names(nm_output)
      nm_output.each_line(chomp: true).filter_map do |line|
        name = line.strip
        name.delete_prefix('_') if !name.empty? && !name.end_with?(':')
      end.uniq.freeze
    end

    def check(undefined_by_object:, inside:, imports:)
      listed = imports.values.flatten
      violations = undefined_by_object.flat_map do |object, names|
        (names - inside - listed).map { |name| Violation.new(object: object, name: name) }
      end
      used = undefined_by_object.values.flatten.uniq
      Report.new(violations: violations.freeze, unused: (listed - used).freeze)
    end

    # The effects: read the objects with nm. The executable is read too, less what
    # liberx itself imports, so a leftover object or a library missing from the
    # list of objects cannot hide what the link really brought in.
    def check_objects(objects:, executable:, liberx:, imports_path:)
      undefined = objects.to_h { |object| [object, symbol_names(nm('-u', object))] }
      undefined[executable] = symbol_names(nm('-u', executable)) - symbol_names(nm('-u', liberx))
      inside = [*objects, liberx].flat_map { |object| defined_names(object) }.uniq
      check(undefined_by_object: undefined, inside: inside, imports: parse_imports(File.read(imports_path)))
    end

    def defined_names(path) = symbol_names(nm('-g', '-U', '-j', path))

    def objects(output)
      libraries = LIBRARIES.map { |library| File.join(output.root, 'erts', library) }
      missing = libraries.reject { |library| File.file?(library) }
      raise Error, "the build left no #{missing.first}" unless missing.empty?

      emulator = Dir[File.join(output.objects, '*.o')]
      raise Error, "the build left no objects in #{output.objects}" if emulator.empty?

      (emulator + libraries).sort
    end

    def nm(*arguments)
      output, error, status = Open3.capture3('nm', *arguments, stdin_data: '')
      raise Error, "nm #{arguments.join(' ')}: #{error.lines.first}" unless status.success?

      output
    end
    private_class_method :nm
  end
end
