# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/arch_terms'

class ArchTermsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('erx-architecture-terms-')
    %w[hw/arch_terms kernel/core kernel/arch/aarch64 docs].each do |path|
      FileUtils.mkdir_p(File.join(@root, path))
    end
    File.write(File.join(@root, 'hw/arch_terms/aarch64.txt'), "word EL1\nprefix ICC_\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def test_seeded_generic_source_violation_is_caught
    source = File.join(@root, 'kernel/core/example.c')
    File.write(source, "int kernel_mode;\n")
    assert Erx::ArchTerms.check(root: @root)
    File.write(source, "int erx_el1_state;\n")
    error = assert_raises(Erx::Error) { Erx::ArchTerms.check(root: @root) }
    assert_includes error.message, 'kernel/core/example.c:1'
  end

  def test_binding_source_and_document_own_their_terms
    File.write(File.join(@root, 'kernel/arch/aarch64/entry.c'), "int ICC_IAR1_EL1;\n")
    File.write(File.join(@root, 'docs/design-arch-aarch64.md'), 'EL1 is kernel mode.')
    assert Erx::ArchTerms.check(root: @root)
    File.write(File.join(@root, 'docs/design-kernel.md'), 'Enter EL1.')
    assert_raises(Erx::Error) { Erx::ArchTerms.check(root: @root) }
  end

  def test_binding_lookalike_nested_inside_generic_core_is_checked
    FileUtils.mkdir_p(File.join(@root, 'kernel/core/hw'))
    File.write(File.join(@root, 'kernel/core/hw/example.c'), "int erx_el1_state;\n")
    assert_raises(Erx::Error) { Erx::ArchTerms.check(root: @root) }
  end

  def test_backend_architecture_binding_owns_its_terms
    directory = File.join(@root, 'liberx/backend/erx/arch/aarch64/generated')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'calls.c'), "int erx_el1_state;\n")
    assert Erx::ArchTerms.check(root: @root)

    File.write(File.join(@root, 'liberx/backend/erx/generic.c'), "int erx_el1_state;\n")
    error = assert_raises(Erx::Error) { Erx::ArchTerms.check(root: @root) }
    assert_includes error.message, 'liberx/backend/erx/generic.c:1'
  end

  def test_policy_is_literal_bounded_and_unique
    ['', "word EL1\nword EL1\n", "regexp .*\n", "word EL[0-3]\n", "\xff".b].each do |bytes|
      assert_raises(Erx::Error) { Erx::ArchTerms.parse(bytes) }
    end
    pattern = Erx::ArchTerms.parse("word EL1\nprefix ICC_\n")
    assert pattern.match?('erx_el1_state')
    assert pattern.match?('ICC_IAR1')
    refute pattern.match?('fieldEL1value')
  end
end
