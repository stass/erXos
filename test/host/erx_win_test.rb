# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'
require_relative '../../tools/lib/erx/memdraw_build'

# Runs test/erlang/erx_win_core_tests.erl, the readers and lines of erx_win_core, and
# test/erlang/erx_win_tests.erl, erx_win with erx_pixels against erx_winfs, erx_window
# and erx_screen, on stock's emulator with erx_memdraw's NIF built for the host
# (Erx::MemdrawBuild.nif). erx's registry and erx_area are stand-ins written here, and
# erx_win's fids, which prim_file draws on erXos, come from a counter of the emulator's.
class ErxWinTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  INCLUDES = %w[otp/lib/kernel/include build/gen/erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  DISPLAY = %w[erx_display erx_screen erx_screen_core erx_wctl erx_window erx_winctl erx_winfs erx_wm
               erx_wm_single].map { |name| "erlang/apps/erx_display/src/#{name}.erl" }
  FILES = %w[erx_fs erx_fs_grant erx_fs_grants erx_fs_version].map { |name| "erlang/apps/erx_files/src/#{name}.erl" }
  CLIENT = %w[erx_win_core erx_pixels erx_pixels_core].map { |name| "erlang/apps/erx_win/src/#{name}.erl" }
  MODULES = (%w[erlang/apps/erx_memdraw/src/erx_memdraw.erl erlang/apps/erx_memdraw/src/erx_chan.erl
                build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl otp/erts/preloaded/src/erx_file_remote.erl
                erlang/apps/erx/src/erx_facet.erl] + DISPLAY + FILES + CLIENT +
             %w[test/erlang/erx_win_core_tests.erl test/erlang/erx_win_tests.erl]).freeze
  FID = 'prim_file:erx_fid()'
  STAND_INS = {
    'erx_log' => <<~ERLANG,
      -module(erx_log).
      -export([debug/1]).
      debug(_Message) -> ok.
    ERLANG
    'erx' => <<~ERLANG,
      -module(erx).
      -export([cap/1, owner/1]).
      cap(Name) -> persistent_term:get({erx_stand_in, cap, Name}, undefined).
      owner(Pid) -> persistent_term:get({erx_stand_in, owner, Pid}).
    ERLANG
    'erx_area' => <<~ERLANG
      -module(erx_area).
      -export([open/1, zero/3]).
      open(Peer) -> persistent_term:get({erx_area_stand_in, Peer}, {error, none}).
      zero(_Area, _Offset, _Pages) -> ok.
    ERLANG
  }.freeze
  DEADLINE_SECONDS = '300'

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-win-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_client_cases
    Erx::MemdrawBuild.nif(root: ROOT, otp: OTP, directory: @directory, compiler: COMPILER)
    sources = MODULES.map { |path| File.join(ROOT, path) } + stand_ins
    text, status = Open3.capture2e(Erx::MemdrawBuild::CLEAN_ENVIRONMENT, File.join(OTP, 'bin/erlc'),
                                   *INCLUDES.flat_map { |dir| ['-I', dir] }, '-o', @directory, *sources,
                                   stdin_data: '')
    assert status.success?, text
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(@directory))
    text, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, File.join(OTP, 'bin/erl'),
                                   '-noshell', '-pa', @directory, '-eval',
                                   'case eunit:test([erx_win_core_tests, erx_win_tests], [verbose]) of ' \
                                   'ok -> halt(0); _ -> halt(1) end.',
                                   chdir: @directory, stdin_data: '')
    assert status.success?, text
    assert_match(/All \d+ tests passed/, text)
  end

  private

  # The stand-ins, and erx_win with its fids drawn from a counter of stock's emulator.
  def stand_ins
    client = File.read(File.join(ROOT, 'erlang/apps/erx_win/src/erx_win.erl'))
    raise "no #{FID} in erx_win.erl" unless client.include?(FID)

    STAND_INS.merge('erx_win' => client.sub(FID, 'erlang:unique_integer([positive])')).map do |name, text|
      File.join(@directory, "#{name}.erl").tap { |path| File.write(path, text) }
    end
  end
end
