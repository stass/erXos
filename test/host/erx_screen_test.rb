# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/host_os'
require_relative '../../tools/lib/erx/memdraw_build'

# Runs test/erlang/erx_screen_tests.erl, erx_screen over a stand-in driver, on stock's
# emulator with erx_memdraw's NIF built for the host (Erx::MemdrawBuild.nif), so the
# fill writes real pixels the test reads back.
class ErxScreenTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  MODULES = %w[erlang/apps/erx_memdraw/src/erx_memdraw.erl erlang/apps/erx_memdraw/src/erx_chan.erl erlang/apps/erx_display/src/erx_screen_core.erl
               erlang/apps/erx_display/src/erx_display.erl erlang/apps/erx_display/src/erx_screen.erl
               erlang/apps/erx_display/src/erx_winfs.erl
               test/erlang/erx_screen_tests.erl].freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  DEADLINE_SECONDS = '120'

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-screen-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_screen_cases
    Erx::MemdrawBuild.nif(root: ROOT, otp: OTP, directory: @directory, compiler: COMPILER)
    text, status = Open3.capture2e(Erx::MemdrawBuild::CLEAN_ENVIRONMENT, File.join(OTP, 'bin/erlc'), '-I', INCLUDE,
                                   '-o', @directory, *MODULES.map { |path| File.join(ROOT, path) }, stdin_data: '')
    assert status.success?, text
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(@directory))
    text, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, File.join(OTP, 'bin/erl'),
                                   '-noshell', '-pa', @directory, '-eval',
                                   'case eunit:test(erx_screen_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.',
                                   chdir: @directory, stdin_data: '')
    assert status.success?, text
    assert_match(/All \d+ tests passed/, text)
  end
end
