# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'

# tools/erx loads on a host that names no LLVM toolchain: a command that compiles
# nothing, such as netboot's help, needs no working compiler, so loading the tool
# must not reach code that looks for one (a test fixture that sets the sanitizer
# environment did, by being loaded). ERX_CLANG names no file, so the test does not
# depend on which clang the host's PATH finds.
class CliWithoutCompilerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_a_command_that_compiles_nothing_runs_without_the_toolchain_variables
    output, status = Open3.capture2e({ 'ERX_CLANG' => File.join(ROOT, 'build/no-such-clang'), 'ERX_LLD' => nil },
                                     RbConfig.ruby, File.join(ROOT, 'tools/erx'), 'netboot', '--help',
                                     chdir: ROOT, stdin_data: '')
    assert status.success?, "tools/erx netboot --help failed with no compiler:\n#{output}"
    assert_match(/--tftp DIR/, output)
  end
end
