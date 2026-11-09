# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'json_input'
require_relative 'dependencies'
require_relative 'generated'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # The terminal emulator's oracle: libvterm 0.3.3 (deps.lock, id `libvterm`)
  # with erXos's harness test/vt/vterm_dump.c, built for the development host
  # into build/vt-oracle (docs/design-display.md, "The oracle"). libvterm's
  # Makefile and libtool never run: this compiles its sources, less
  # unicode.c, whose two width functions the harness supplies from the
  # generated include/erx/vt_width.h, and links them with the harness.
  module VtOracle
    SOURCE_ID = 'libvterm'
    OUTPUT = 'build/vt-oracle'
    PROGRAM = 'vterm_dump'
    STAMP = 'build.json'
    HARNESS = 'test/vt/vterm_dump.c'
    WIDTH_HEADER = 'include/erx/vt_width.h'
    # libvterm's sources but unicode.c, which the harness replaces.
    SOURCES = %w[encoding keyboard mouse parser pen screen state vterm].freeze
    # libvterm's own sources are built quietly; the harness is erXos's C17.
    CFLAGS = %w[-std=c17 -O2 -w].freeze
    DEADLINE = 600

    module_function

    # The built harness, or nil when it is missing or was built from another
    # pin, recipe, harness or width table, so a caller rebuilds it.
    def locate(root:)
      program = File.join(root, OUTPUT, PROGRAM)
      stamp = File.join(root, OUTPUT, STAMP)
      return nil unless File.file?(program) && File.file?(stamp)

      recorded = begin
        JsonInput.parse(BoundedFile.read(stamp, maximum: 65_536), max_bytes: 65_536, label: "vt oracle build record")
      rescue JsonInput::Unsupported
        raise
      rescue Error
        nil
      end
      recorded == record(root: root) ? program : nil
    end

    # The harness, built first when locate refuses what is there.
    def ensure(root:, runner:)
      locate(root: root) || build(root: root, runner: runner)
    end

    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    def record(root:)
      { 'source' => source_record(root: root),
        'recipe' => Digest::SHA256.file(__FILE__).hexdigest,
        'harness' => Digest::SHA256.file(File.join(root, HARNESS)).hexdigest,
        'widths' => Digest::SHA256.file(Generated.path(WIDTH_HEADER, root: root)).hexdigest,
        'compiler' => ENV.fetch('CC', 'cc') }
    end

    def build(root:, runner:, compiler: ENV.fetch('CC', 'cc'))
      Generated.ensure(root: root)
      tree = Dependencies.new(root: root, runner: runner).fetched_tree(SOURCE_ID)
      build = OutputDirectory.prepare(root: root, path: File.join(root, 'build'))
      Dir.mktmpdir('.vt-oracle-', build) do |work|
        output = File.join(work, 'out')
        Dir.mkdir(output)
        sources = [*SOURCES.map { |name| File.join(tree, 'src', "#{name}.c") }, File.join(root, HARNESS)]
        includes = [File.join(tree, 'include'), File.join(tree, 'src'), File.join(root, Generated::OUTPUT, 'include')]
        runner.run([compiler, *CFLAGS, *includes.map { |path| "-I#{path}" }, '-o', File.join(output, PROGRAM), *sources],
                   name: 'vt-oracle-build', deadline: DEADLINE, chdir: work)
        File.write(File.join(output, STAMP), JSON.pretty_generate(record(root: root)) + "\n")
        publish(output, destination: File.join(root, OUTPUT))
      end
      locate(root: root) || raise(Error, "vt oracle build left no #{PROGRAM} in #{OUTPUT}")
    end

    # The new output replaces the old whole.
    def publish(output, destination:)
      raise Error, "vt oracle output is a symbolic link: #{destination}" if File.symlink?(destination)

      FileUtils.rm_rf(destination)
      File.rename(output, destination)
    end
  end
end
