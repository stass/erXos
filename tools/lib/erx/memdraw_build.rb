# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'abi'
require_relative 'error'

module Erx
  # erx_memdraw built for the development host (docs/design-display.md, "The
  # pixel primitives"): the NIF as a bundle that stock's emulator loads, with
  # the test-only cload/3, or a program linked with a harness; and the
  # Erlang side of test/erlang/erx_memdraw_tests.erl, which
  # test/host/erx_memdraw_test.rb and tools/fuzz/erx_memdraw_y.rb run.
  # A seed replaces one passage of one source in a copy, so a test can show
  # its check fails on the fault it guards.
  module MemdrawBuild
    LIBMEMDRAW = 'display/libmemdraw'
    MEMDRAW = 'display/memdraw'
    # The files of 9front's libmemdraw and libdraw that erXos imported (display/libmemdraw/ORIGIN.md).
    IMPORTED = %w[alloc arith badrect bytesperline chan cload cmap draw drawrepl load rectclip unload].freeze
    OURS = %w[erx_draw_clip erx_memdraw].freeze
    # The imported files keep Plan 9's pragmas and USED(a, b).
    WARNINGS = %w[-Wall -Wno-unknown-pragmas -Wno-unused-value -Wno-unused-function -Werror].freeze
    NIF_FLAGS = %w[-bundle -undefined dynamic_lookup -DERX_MEMDRAW_LOADABLE].freeze
    # UBSan without its runtime: a stock emulator cannot load ASan's into a NIF.
    TRAP_UB = %w[-fsanitize=undefined -fsanitize-trap=undefined].freeze
    SANITIZE = %w[-fsanitize=address,undefined -fno-sanitize-recover=all].freeze
    DEADLINE = '300'
    MODULES = %w[erlang/apps/erx_display/src/erx_draw_image.erl erlang/apps/erx_display/src/erx_draw_core.erl
                 erlang/apps/erx_display/src/erx_memdraw.erl test/erlang/erx_draw_ref.erl
                 test/erlang/erx_memdraw_tests.erl].freeze
    # The emulator ignores the caller's flags and code path.
    CLEAN_ENVIRONMENT = { 'ERL_AFLAGS' => nil, 'ERL_FLAGS' => nil, 'ERL_ZFLAGS' => nil, 'ERL_LIBS' => nil }.freeze

    Seed = Data.define(:path, :from, :to)

    module_function

    # The NIF bundle erx_memdraw.so in directory, for stock OTP's headers at otp.
    def nif(root:, otp:, directory:, compiler:, seed: nil)
      sources = sources(root: root, directory: directory, seed: seed) << File.join(root, MEMDRAW, 'erx_memdraw_nif.c')
      compile(compiler, [*NIF_FLAGS, *TRAP_UB, '-I', File.join(otp, 'usr/include')], sources,
              File.join(directory, 'erx_memdraw.so'), root: root)
    end

    # The NIF, the generated draw codec and MODULES compiled into directory.
    def erlang_cases(root:, otp:, directory:, compiler:, seed: nil)
      nif(root: root, otp: otp, directory: directory, compiler: compiler, seed: seed)
      codec = File.join(directory, 'erx_draw_codec.erl')
      File.write(codec, ABI::Generator.plan(root: root).files.fetch(ABI::DrawEmitter::ERLANG_PATH))
      erlc(otp: otp, directory: directory, sources: [codec, *MODULES.map { |path| File.join(root, path) }])
    end

    def erlc(otp:, directory:, sources:)
      text, status = Open3.capture2e(CLEAN_ENVIRONMENT, File.join(otp, 'bin/erlc'), '-o', directory, *sources,
                                     stdin_data: '')
      raise Error, "erlc failed:\n#{text}" unless status.success?
    end

    # The one line erx_memdraw_tests:main/1 prints for mode, or all its output
    # when it crashed before printing it.
    def run_cases(otp:, directory:, mode:, rounds:, seed:)
      text, = Open3.capture2e(CLEAN_ENVIRONMENT, 'gtimeout', '-k', '10', DEADLINE, File.join(otp, 'bin/erl'),
                              '-noshell', '-pa', directory, '-run', 'erx_memdraw_tests', 'main', mode, seed.to_s,
                              rounds.to_s, chdir: directory, stdin_data: '')
      text.lines.find { |line| line.start_with?("#{mode} ") }&.chomp || text
    end

    # A program of harness and erx_memdraw, under ASan and UBSan.
    def program(root:, harness:, directory:, compiler:, seed: nil)
      sources = sources(root: root, directory: directory, seed: seed) << File.join(root, harness)
      compile(compiler, SANITIZE, sources, File.join(directory, File.basename(harness, '.c')), root: root)
    end

    def sources(root:, directory:, seed:)
      paths = [*IMPORTED.map { |name| File.join(LIBMEMDRAW, "#{name}.c") }, *OURS.map { |name| File.join(MEMDRAW, "#{name}.c") }]
      paths.map { |path| seed&.path == path ? seeded(root, directory, seed) : File.join(root, path) }
    end

    def seeded(root, directory, seed)
      text = File.read(File.join(root, seed.path))
      raise Error, "seed passage not found once in #{seed.path}" unless text.scan(seed.from).size == 1

      copy = File.join(directory, "seeded-#{File.basename(seed.path)}")
      File.write(copy, text.sub(seed.from) { seed.to })
      copy
    end

    def compile(compiler, flags, sources, output, root:)
      includes = ['-I', File.join(root, LIBMEMDRAW), '-I', File.join(root, MEMDRAW)]
      command = [compiler, '-std=c17', '-g', '-O1', *WARNINGS, '-DERX_MEMDRAW_CLOAD', *flags, *includes, '-o', output,
                 *sources]
      text, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, stdin_data: '')
      raise Error, "erx_memdraw build failed:\n#{text}" unless status.success?

      output
    end
  end
end
