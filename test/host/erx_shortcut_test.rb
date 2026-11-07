# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_shortcut_tests.erl, the collision test of erXos's
# shell shortcuts, on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies), against erXos's shell_default compiled from its source
# into a directory of its own, so stock's shell_default stays the one loaded.
class ErxShortcutTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SHELL_DEFAULT = File.join(ROOT, 'otp/lib/stdlib/src/shell_default.erl')
  TESTS = File.join(ROOT, 'test/erlang/erx_shortcut_tests.erl')

  def test_shortcuts_collide_with_nothing
    Dir.mktmpdir('erx-shortcut-test') do |work|
      ours = File.join(work, 'erxos')
      Dir.mkdir(ours)
      compile(ours, SHELL_DEFAULT)
      compile(work, TESTS)

      output, status = Open3.capture2e({ 'ERX_SHELL_DEFAULT_BEAM' => File.join(ours, 'shell_default.beam') },
                                       'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shortcut_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  def compile(directory, source)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', directory, source, stdin_data: '')
    assert status.success?, output
  end
end
