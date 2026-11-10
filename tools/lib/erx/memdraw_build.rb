# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'json_input'
require_relative 'error'
require_relative 'host_os'

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
    IMPORTED = %w[alloc arc arith badrect bytesperline chan cload cmap draw drawrepl ellipse fillpoly icossin icossin2 line
                  load poly rectclip unload].freeze
    OURS = %w[erx_draw_clip erx_memdraw].freeze
    # The imported files keep Plan 9's pragmas and USED(a, b).
    WARNINGS = %w[-Wall -Wno-unknown-pragmas -Wno-unused-value -Wno-unused-function -Werror].freeze
    NIF_FLAGS = [*HostOs::NIF_LINK_FLAGS, '-DERX_MEMDRAW_LOADABLE'].freeze
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
      environment = CLEAN_ENVIRONMENT.merge(HostOs.nif_search_environment(directory))
      text, = Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE, File.join(otp, 'bin/erl'),
                              '-noshell', '-pa', directory, '-run', 'erx_memdraw_tests', 'main', mode, seed.to_s,
                              rounds.to_s, chdir: directory, stdin_data: '')
      text.lines.find { |line| line.start_with?("#{mode} ") }&.chomp || text
    end

    # A program of harness and erx_memdraw, under ASan and UBSan.
    def program(root:, harness:, directory:, compiler:, seed: nil)
      sources = sources(root: root, directory: directory, seed: seed) << File.join(root, harness)
      compile(compiler, SANITIZE, sources, File.join(directory, File.basename(harness, '.c')), root: root)
    end

    # The 9front build (docs/design-display.md, "The pixel primitives"):
    # 9front's libmemdraw and the parts of libdraw it links, unmodified
    # from the fetched pin, compiled for the host against erXos's
    # test/display/memdraw_oracle headers and the pin's own draw.h,
    # memdraw.h and memlayer.h (copied, so the pin's other system headers
    # never shadow the host's), with harness built -DERX_ORACLE.
    ORACLE_SOURCES = { 'libmemdraw' => %w[alloc arc cmap draw ellipse fillpoly hwdraw line load poly unload],
                       'libdraw' => %w[arith badrect bytesperline chan drawrepl icossin icossin2 rectclip] }.freeze
    ORACLE_HEADERS = %w[draw.h memdraw.h memlayer.h].freeze
    ORACLE_SHIM = 'test/display/memdraw_oracle'
    NINEFRONT = '9front'

    def oracle(root:, harness:, directory:, compiler:)
      tree = ninefront_tree(root)
      headers = File.join(directory, 'oracle-include')
      FileUtils.mkdir_p(headers)
      ORACLE_HEADERS.each { |name| FileUtils.cp(File.join(tree, 'sys/include', name), headers) }
      sources = ORACLE_SOURCES.flat_map { |lib, names| names.map { |name| File.join(tree, 'sys/src', lib, "#{name}.c") } }
      output = File.join(directory, "#{File.basename(harness, '.c')}-9front")
      # Plan 9's qsort comparators take void *, and its sources warn freely.
      command = [compiler, '-std=c17', '-g', '-O1', '-w', '-Wno-incompatible-function-pointer-types', '-DERX_ORACLE', '-I', File.join(root, ORACLE_SHIM), '-I', headers,
                 '-o', output, File.join(root, harness), *sources]
      text, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, stdin_data: '')
      raise Error, "9front build failed:\n#{text}" unless status.success?

      output
    end

    # The fetched 9front tree, only as deps.lock pins it.
    def ninefront_tree(root)
      pin = DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                            .find { |source| source.fetch('id') == NINEFRONT } ||
            raise(Error, "deps.lock has no #{NINEFRONT} source")
      parent = File.join(root, 'build/third_party', NINEFRONT)
      marker = File.join(parent, '.source.json')
      recorded = File.file?(marker) &&
                 JsonInput.parse(BoundedFile.read(marker, maximum: 65_536), max_bytes: 65_536,
                                 label: 'source download record')
      unless recorded == pin
        raise Error, "9front is not fetched at deps.lock's pin: run tools/erx fetch --source #{NINEFRONT}"
      end

      File.join(parent, pin.fetch('directory'))
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
