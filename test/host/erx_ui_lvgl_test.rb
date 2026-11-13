# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/lvgl'

# The LVGL renderer's shell, erx_ui_lvgl, around erx_ui_lvgl_core, driving the real
# erx-lvgl on the host through test/erlang/erx_ui_lvgl_shell.erl (docs/design-display.md,
# "The widget server"): an apply is written and answered, a click sent while a report is
# open waits for its answer, a window grown past its buffer ends the UI as renderer_down,
# and a close ends the shell with no fault.
class ErxUiLvglTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  LAUNCHER = File.join(ROOT, 'test/fixtures/erx_lvgl_buffer.rb')
  APPLICATIONS = %w[erx erx_win].freeze
  TESTS = %w[test/erlang/erx_ui_lvgl_shell.erl].freeze

  def test_the_shell_drives_the_program
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-ui-lvgl-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      paths = { program: program, ruby: RbConfig.ruby, launcher: LAUNCHER }.map { |key, path| "#{key} => #{path.inspect}" }
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', "io:format(\"~p~n\", [erx_ui_lvgl_shell:run(\#{#{paths.join(', ')}})]), halt(0)",
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/first => \{240,160\}/, output)
      assert_match(/held => \[\]/, output)
      assert_match(/hit => \{ui_hit,3,on_click,none\}/, output)
      assert_match(/grown => \{renderer_down,\{shutdown,\{renderer_down,\{exit,1\}\}\}\}/, output)
      assert_match(/closed => \{normal,\[\]\}/, output)
      assert_match(/killed => \{renderer_down,\{shutdown,\{renderer_down,\{exit,137\}\}\}\}/, output)
    end
  end
end
