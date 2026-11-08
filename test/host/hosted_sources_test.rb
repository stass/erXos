# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/hosted_sources'

class HostedSourcesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  # Each architecture's file guards its body by the compiler's target, so the
  # hosted build can list them all and link only the one it assembled.
  def test_every_stack_switch_is_built
    switches = Dir.glob('liberx/backend/hosted/arch/*/switch_stack.S', base: ROOT).sort
    assert_includes switches, 'liberx/backend/hosted/arch/x86_64/switch_stack.S'
    assert_equal switches, Erx::HostedSources::ALL.grep(/switch_stack/).sort
  end

  def test_every_stack_switch_guards_its_body_by_the_target
    Dir.glob('liberx/backend/hosted/arch/*/switch_stack.S', base: ROOT).each do |path|
      arch = path.split('/').fetch(-2)
      text = File.read(File.join(ROOT, path))
      assert_match(/^#if defined\(__#{arch}__\)\n/, text, path)
      assert_match(/^#endif\n\z/, text, path)
    end
  end
end
