# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

class SanitizerGateTest < Minitest::Test
  def setup
    root = File.expand_path('../..', __dir__)
    parent = File.join(root, 'build/test')
    FileUtils.mkdir_p(parent)
    @directory = Dir.mktmpdir('sanitizer-gate-', parent)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
  end

  def test_recoverable_undefined_behavior_fails_the_command
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    environment = Erx::CLI.send(:host_environment, runner: runner, purpose: :host_tests)
    source = File.join(@directory, 'overflow.c')
    program = File.join(@directory, 'overflow')
    File.write(source, "#include <limits.h>\nint main(void) { volatile int value = INT_MAX; value += 1; return 0; }\n")
    runner.run([environment.fetch('ERX_CLANG'), '-std=c17', '-fsanitize=undefined',
                source, '-o', program], name: 'compile-intentional-ub', deadline: 60, env: environment)
    error = assert_raises(Erx::CommandError) do
      runner.run([program], name: 'intentional-ub', deadline: 30, env: environment)
    end
    assert_includes File.binread(error.result.fetch('log')), 'signed integer overflow'
  end
end
