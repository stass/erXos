# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/host_os'
require_relative '../../tools/lib/erx/memdraw_build'

# Runs test/erlang/erx_winfs_tests.erl: erx_winfs, erx_window, erx_screen and erx_fb_sup's
# start of erx_winfs, with the erx_fs grants of erx_files, on stock's emulator with
# erx_memdraw's NIF built for the host (Erx::MemdrawBuild.nif), whose stand-in pixel
# area the windows present from.
class ErxWinfsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  GRAMMAR = 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl'
  DISPLAY = %w[erx_display erx_screen erx_screen_core erx_wctl erx_window erx_winctl erx_winfs erx_wm
               erx_wm_single erx_input].map { |name| "erlang/apps/erx_display/src/#{name}.erl" } +
            ['build/gen/erlang/apps/erx_display/src/erx_keymap.erl']
  FILES = %w[erx_fs erx_fs_grant erx_fs_grants erx_fs_version].map { |name| "erlang/apps/erx_files/src/#{name}.erl" }
  MODULES = (['erlang/apps/erx_memdraw/src/erx_memdraw.erl', 'erlang/apps/erx_memdraw/src/erx_chan.erl', GRAMMAR] + DISPLAY + FILES +
             ['erlang/apps/erx/src/erx_facet.erl', 'erlang/apps/erx_fb/src/erx_fb_sup.erl', 'test/erlang/erx_winfs_tests.erl']).freeze
  # The display's log is the debug log of erx_log's NIF, which stock's emulator has not.
  LOG_STUB = <<~ERLANG
    -module(erx_log).
    -export([debug/1]).
    debug(_Message) -> ok.
  ERLANG
  DEADLINE_SECONDS = '300'

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-winfs-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_window_system_cases
    Erx::MemdrawBuild.nif(root: ROOT, otp: OTP, directory: @directory, compiler: COMPILER)
    File.write(File.join(@directory, 'erx_log.erl'), LOG_STUB)
    sources = MODULES.map { |path| File.join(ROOT, path) } + [File.join(@directory, 'erx_log.erl')]
    text, status = Open3.capture2e(Erx::MemdrawBuild::CLEAN_ENVIRONMENT, File.join(OTP, 'bin/erlc'),
                                   '-I', INCLUDE, '-o', @directory, *sources, stdin_data: '')
    assert status.success?, text
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(@directory))
    text, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, File.join(OTP, 'bin/erl'),
                                   '-noshell', '-pa', @directory, '-eval',
                                   'case eunit:test(erx_winfs_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.',
                                   chdir: @directory, stdin_data: '')
    assert status.success?, text
    assert_match(/All \d+ tests passed/, text)
  end
end
