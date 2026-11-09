# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require_relative 'error'
require_relative 'runtime'

module Erx
  # `make check-runtime-seam`'s name check (docs/design-runtime.md, "What ERTS
  # imports"): ERTS's objects import from outside themselves only the names in
  # sys/erxos/imports.txt, whose [liberx] and [liberx_hosted] sections hold the liberx calls ERTS makes. What
  # else liberx defines counts as outside, so a call to a backend's internal name fails.
  module RuntimeSeam
    Violation = Data.define(:object, :name)
    Report = Data.define(:violations, :unused)
    IMPORTS_FILE = 'erts/emulator/sys/erxos/imports.txt'
    # Sections only the hosted build uses: libSystem's names, the liberx calls only
    # hosted objects make, and the calls of erx_stdio_nif.c, an object the native build
    # does not link. The native check leaves them out, so they do not count as unused there.
    HOSTED_ONLY = %w[libsystem liberx_hosted only_erx_stdio_nif].freeze
    # erx_domain_lib_nif.c, whose domain library the hosted build does not link, is native too.
    NATIVE_ONLY = %w[musl stock_native only_erx_domain_lib_nif].freeze
    # Sections only the BeamAsm flavour's objects use: the hosted build and the native
    # interpreter leave them out.
    JIT_ONLY = %w[beamasm].freeze
    NAME = /\A[A-Za-z_][A-Za-z0-9_$.]*\z/
    OWN_LIST_PREFIX = 'only_'

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

    # A section named only_OBJECT lists what the one object OBJECT.o may use besides.
    def check(undefined_by_object:, inside:, imports:)
      shared = shared_names(imports)
      violations = undefined_by_object.flat_map do |object, names|
        own = imports.fetch("#{OWN_LIST_PREFIX}#{File.basename(object, '.o')}", [])
        (names - inside - shared - own).map { |name| Violation.new(object: object, name: name) }
      end
      used = undefined_by_object.values.flatten.uniq
      Report.new(violations: violations.freeze, unused: (imports.values.flatten - used).freeze)
    end

    def shared_names(imports) = imports.reject { |section, _| section.start_with?(OWN_LIST_PREFIX) }.values.flatten
    def own_names(imports) = imports.select { |section, _| section.start_with?(OWN_LIST_PREFIX) }.values.flatten

    # The effects: read the objects with nm. The executable is checked as one more
    # object, so that a leftover object or a library missing from the list cannot hide
    # what the link really brought in. Its undefined names leave out two groups that
    # are checked elsewhere: those liberx's own object leaves undefined, and the names
    # of the own lists, which their one object answers for.
    def check_objects(objects:, executable:, liberx:, imports_path:)
      undefined = objects.to_h { |object| [object, symbol_names(nm('-u', object))] }
      imports = parse_imports(File.read(imports_path)).except(*NATIVE_ONLY, *JIT_ONLY)
      undefined[executable] = symbol_names(nm('-u', executable)) - symbol_names(nm('-u', liberx)) - own_names(imports)
      inside = objects.flat_map { |object| defined_names(object) }.uniq
      check(undefined_by_object: undefined, inside: inside, imports: imports)
    end

    # The native build's check: ELF objects and archives through llvm-nm, whose C names
    # carry no prefix. OTP's own link of beam.emu has already shown that no name is missing.
    # cxx_runtime are the archives of the C++ runtime the BeamAsm image links: what they
    # define counts as inside, and the sections only BeamAsm uses join the list. Without
    # them those sections stay out, so they do not count as unused.
    def check_elf_objects(objects:, imports_text:, nm:, cxx_runtime: [])
      names = lambda do |*arguments|
        output, error, status = Open3.capture3(nm, '--format=just-symbols', *arguments, stdin_data: '')
        raise Error, "llvm-nm #{arguments.join(' ')}: #{error.lines.first}" unless status.success?

        output.each_line(chomp: true).reject { |line| line.empty? || line.end_with?(':') }.uniq
      end
      check(undefined_by_object: objects.to_h { |object| [object, names.call('--undefined-only', object)] },
            inside: (objects + cxx_runtime).flat_map { |object| names.call('--defined-only', '--extern-only', object) }.uniq,
            imports: parse_imports(imports_text).except(*HOSTED_ONLY, *(cxx_runtime.empty? ? JIT_ONLY : [])))
    end

    def defined_names(path) = symbol_names(nm('-g', '-U', '-j', path))

    # The libraries the emulator links beside its own objects.
    def libraries(output, target: Runtime::TARGET)
      %W[
        emulator/pcre/obj/#{target}/opt/libepcre.a emulator/ryu/obj/#{target}/opt/libryu.a
        emulator/zlib/obj/#{target}/opt/libz.a emulator/zstd/obj/#{target}/opt/libzstd.a
        lib/internal/#{target}/libethread.a lib/internal/#{target}/liberts_internal_r.a
      ].map { |library| File.join(output.root, 'erts', library) }
    end

    # What the check reads as ERTS: never liberx, whose names count as outside.
    def objects(output, target: Runtime::TARGET)
      libraries = libraries(output, target: target)
      missing = libraries.reject { |library| File.file?(library) }
      raise Error, "the build left no #{missing.first}" unless missing.empty?

      # The BeamAsm flavour keeps asmjit's objects in subdirectories of its own.
      emulator = Dir[File.join(output.objects, '**/*.o')]
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
