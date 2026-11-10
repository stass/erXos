# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'

# The littlefs NIF (otp/erts/emulator/nifs/erxos/erx_littlefs_nif.c) built for the host,
# loaded into the stock OTP 29.1.2 runtime, and driven with erx_lfs over a RAM window by
# test/fixtures/erx_littlefs_tests.erl, on one dirty I/O scheduler. The runtime runs
# uninstrumented: a loaded NIF under AddressSanitizer needs DYLD_INSERT_LIBRARIES, which
# the development host's sandbox strips (TODO.md, storage); the image fuzz target runs
# littlefs under both sanitizers.
class ErxLittlefsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  LITTLEFS = File.join(ROOT, 'littlefs')
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-DERX_LITTLEFS_LOADABLE', '-DLFS_NO_DEBUG', '-DLFS_NO_WARN', '-DLFS_NO_ERROR'].freeze
  MODULES = ['erlang/apps/erx_files/src/erx_fs.erl', 'erlang/apps/erx_files/src/erx_fs_version.erl',
             'erlang/apps/erx_files/src/erx_littlefs.erl', 'erlang/apps/erx_files/src/erx_lfs.erl',
             'erlang/apps/erx_blk/src/erx_blk_window.erl', 'test/fixtures/erx_littlefs_tests.erl'].freeze
  # erx_log's NIF is the guest's. The stub drops the line: standard_error's writer is a
  # dirty I/O NIF, which the test's one dirty I/O thread may be holding.
  LOG_STUB = <<~ERLANG
    -module(erx_log).
    -export([debug/1]).
    debug(_Message) -> ok.
  ERLANG
  CASES = %w[synced_file_survives_a_cut tree_operations block_error_fails_the_volume
             deadline_ends_a_request refuses_bad_arguments].freeze

  def test_volume_cases_pass_under_one_dirty_io_scheduler
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)

    Dir.mktmpdir('erx-littlefs-') do |directory|
      build_nif(directory)
      compile_modules(directory)
      output = run_cases(directory)
      CASES.each { |name| assert_match(/^ok #{name}$/, output) }
      refute_match(/FAIL|ERROR: AddressSanitizer|runtime error:/, output)
    end
  end

  private

  def build_nif(directory)
    output, status = Open3.capture2e(
      COMPILER, *FLAGS, *Erx::HostOs::NIF_LINK_FLAGS,
      '-I', File.join(OTP, 'usr/include'), '-I', LITTLEFS, '-I', NIFS,
      File.join(NIFS, 'erx_littlefs_nif.c'), File.join(LITTLEFS, 'lfs.c'), File.join(LITTLEFS, 'lfs_util.c'),
      '-o', File.join(directory, 'erx_littlefs.so'), stdin_data: ''
    )
    assert status.success?, output
  end

  def compile_modules(directory)
    File.write(File.join(directory, 'erx_log.erl'), LOG_STUB)
    sources = [File.join(directory, 'erx_log.erl'), *MODULES.map { |path| File.join(ROOT, path) }]
    output, status = Open3.capture2e(clean_environment, File.join(OTP, 'bin/erlc'), '-pa', directory,
                                     '-I', File.join(ROOT, 'build/gen/erlang/apps/erx/include'), '-o', directory,
                                     *sources, stdin_data: '')
    assert status.success?, output
  end

  def run_cases(directory)
    bin = File.join(Dir.glob(File.join(OTP, 'erts-*')).first, 'bin')
    environment = clean_environment.merge(
      Erx::HostOs.nif_search_environment(directory),
      'BINDIR' => bin
    )
    output, = Open3.capture2e(environment, 'gtimeout', '-k', '10', '120', File.join(bin, 'beam.smp'),
                              '-SDio', '1', '--', '-root', OTP, '-bindir', bin, '-progname', 'erl',
                              '-home', directory, '--', '-noshell', '-pa', directory,
                              '-eval', 'erx_littlefs_tests:main()', chdir: directory, stdin_data: '')
    output
  end

  def clean_environment
    { 'ERL_AFLAGS' => nil, 'ERL_FLAGS' => nil, 'ERL_ZFLAGS' => nil, 'ERL_LIBS' => nil }
  end
end
