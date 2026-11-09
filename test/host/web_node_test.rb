# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/web_stage'

# The web client's pure modules under Node's test runner (docs/design-web.md,
# "Verification and testing"): every web/**/*.test.ts, run from the staged
# tree in which the generated modules sit beside the checked-in sources.
class WebNodeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_node_test_runner_passes
    Erx::WebStage.with(root: ROOT) do |stage|
      tests = Dir.glob('**/*.test.ts', base: stage).sort
      refute_empty tests, 'no web tests found'
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *Erx::WebStage::NODE, '--test', *tests,
                                       chdir: stage, stdin_data: '')
      assert status.success?, output
    end
  end
end
