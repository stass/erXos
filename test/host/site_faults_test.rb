# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'

# Runs test/site/terminal_test.mjs, the Node tests of site/terminal.js's pure
# parts (the boot-log parse behind Corrupt RAM, the fault table and the disk
# faults against a stand-in for v64), under a deadline. Node is what the
# site's build already needs, so a host without it fails here.
class SiteFaultsTest < Minitest::Test
  REPO = File.expand_path('../..', __dir__)
  SCRIPT = File.join(REPO, 'test/site/terminal_test.mjs')
  DEADLINE_SECONDS = '60'

  def node
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'node') }
       .find { |path| File.executable?(path) }
  end

  def test_the_terminal_scripts_pure_parts_pass_their_node_tests
    assert node, 'node is not installed; the site build needs it too (brew install node)'

    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, node, '--test', SCRIPT,
                                     chdir: REPO, stdin_data: '')
    assert status.success?, "node --test #{SCRIPT} failed:\n#{output}"
  end
end
