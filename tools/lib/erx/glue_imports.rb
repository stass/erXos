# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bounded_file'
require_relative 'error'

module Erx
  # The allowlist of what the stopgap's glue may call in Fiasco
  # (docs/design-stopgap.md, "Interfaces"). fiasco/erx_glue_imports.txt has
  # one `SYMBOL EFFECT FILE` per line: the symbol, what the glue uses it for,
  # and the glue file that may reference it. A glue object with an undefined
  # symbol its file does not list fails the build, so a deleted path or a raw
  # allocator cannot be reached by adding a call.
  module GlueImports
    ALLOWLIST = 'erx_glue_imports.txt'
    GLUE = 'src/erx'
    MAX_ALLOWLIST_BYTES = 1 << 20
    # The linker's own helpers and the cores' interface need no entry.
    IMPLICIT = /\A(?:erx_[a-z0-9_]{1,1000}|__stack_chk_[a-z]{1,16})\z/
    # The kernel-call route: its sources stay, and Fiasco's Modules.generic
    # builds neither (docs/design-stopgap.md, "Boot handoff").
    OUT_OF_BUILD = %w[erx_probe.cpp erx_syscall.cpp].freeze
    Entry = Data.define(:symbol, :effect, :file)

    module_function

    def parse(text)
      text.each_line.with_index(1).filter_map do |line, number|
        fields = line.strip.split
        next if fields.empty? || fields.first.start_with?('#')
        raise Error, "malformed glue import at #{ALLOWLIST}:#{number}" unless fields.size == 3

        Entry.new(symbol: fields[0], effect: fields[1], file: fields[2])
      end.freeze
    end

    # undefined maps each glue file's name to its object's undefined symbols.
    # Every refusal names the symbol and the file, and an entry nothing
    # references is refused too, so the list stays what the glue uses.
    def violations(entries:, undefined:)
      unlisted = undefined.flat_map do |file, symbols|
        allowed = entries.select { |entry| entry.file == file }.map(&:symbol)
        (symbols.grep_v(IMPLICIT) - allowed).map { |symbol| "#{file}: #{symbol} is not in #{ALLOWLIST}" }
      end
      stale = entries.reject { |entry| undefined.fetch(entry.file, []).include?(entry.symbol) }.map do |entry|
        "#{entry.file}: #{entry.symbol} is listed in #{ALLOWLIST} and no longer referenced"
      end
      unlisted + stale
    end

    # `nm -u` lists one undefined symbol per line, after its type: U, or w or v when weak.
    def undefined_symbols(listing)
      listing.each_line.filter_map do |line|
        fields = line.split
        fields.last if fields.size == 2 && %w[U w v].include?(fields.first)
      end.uniq.freeze
    end

    # The glue a kernel build holds, of the files in its directory.
    def built_glue(names) = (names - OUT_OF_BUILD).sort.freeze

    # The effect: reads each glue object of a kernel build and refuses it.
    def check(source:, allowlist:, objects:, runner:, env: {})
      entries = parse(BoundedFile.read(allowlist, maximum: MAX_ALLOWLIST_BYTES))
      undefined = built_glue(Dir.glob('*.cpp', base: File.join(source, GLUE))).to_h do |name|
        object = File.join(objects, "#{File.basename(name, '.cpp')}.o")
        raise Error, "glue object not built: #{object}" unless File.file?(object)

        result = runner.run(['aarch64-elf-nm', '-u', object], name: "glue-imports-#{File.basename(object, ".o")}",
                                                              deadline: 30, env: env)
        [name, undefined_symbols(BoundedFile.read(result.fetch('log'), maximum: MAX_ALLOWLIST_BYTES))]
      end
      refused = violations(entries: entries, undefined: undefined)
      raise Error, "glue imports:\n#{refused.join("\n")}" unless refused.empty?
    end
  end
end
