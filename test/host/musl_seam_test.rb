# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/musl'

# Only liberx reaches the kernel: every CPU source of musl's that traps has a
# replacement under the erxos arch (docs/design-stopgap.md, "musl over the backend").
class MuslSeamTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_the_tree_leaves_no_trap_unreplaced
    assert_empty Erx::Musl.unreplaced_traps(File.join(ROOT, 'musl'))
  end

  def test_the_call_layer_is_the_archs_own
    refute_match(/\bsvc\b/n, File.binread(File.join(ROOT, 'musl/arch/erxos/syscall_arch.h')).gsub(%r{/\*.*?\*/}mn, ''))
  end

  def test_a_trap_with_no_replacement_is_named
    Dir.mktmpdir do |source|
      trapping = File.join(source, 'src/thread/aarch64/seeded.s')
      FileUtils.mkdir_p(File.dirname(trapping))
      File.write(trapping, "\tsvc 0\n")
      assert_equal [trapping], Erx::Musl.unreplaced_traps(source)

      replacement = File.join(source, 'src/thread/erxos/seeded.c')
      FileUtils.mkdir_p(File.dirname(replacement))
      File.write(replacement, "int seeded;\n")
      assert_empty Erx::Musl.unreplaced_traps(source)
    end
  end
end
