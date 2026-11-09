# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/lvgl'

# erx-lvgl end to end on the host (docs/design-display.md, "The widget
# server"): the program, built from LVGL's pin under ASan and UBSan, is run
# by the model screen test/erlang/erx_lvgl_screen.erl on stock's emulator
# (ERX_ERL and ERX_ERLC), which encodes the server's records with the
# generated erx_ui_wire and reads the program's reports and events with it.
# The model screen says what it checks.
class ErxLvglTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GENERATED = File.join(ROOT, Erx::Generated::OUTPUT)
  SOURCES = [
    File.join(GENERATED, Erx::ABI::UIWireEmitter::ERLANG_PATH),
    File.join(ROOT, 'erlang/apps/erx_display/src/erx_ui_model.erl'),
    File.join(ROOT, 'test/erlang/erx_lvgl_screen.erl')
  ].freeze

  def test_model_screen_drives_the_program
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-lvgl-test') do |work|
      run!(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, chdir: work)
      %w[x8r8g8b8 r5g6b5].each do |channel|
        output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "io:format(\"~p~n\", [erx_lvgl_screen:run(\"#{program}\", #{channel})]), halt(0)", chdir: work)
        assert_match(/events => \[\{event,3,on_click,none\}\]/, output, channel)
      end
    end
  end

  private

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
