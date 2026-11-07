# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/fiasco_inputs'

class FiascoInputsTest < Minitest::Test
  def test_linked_build_ancestor_is_refused_before_creating_any_directory
    Dir.mktmpdir do |temporary|
      project = File.join(temporary, 'project')
      outside = File.join(temporary, 'outside')
      FileUtils.mkdir_p([project, outside])
      File.symlink(outside, File.join(project, 'build'))
      assert_raises(Erx::Error) { Erx::FiascoInputs.new(root: project).prepare }
      refute File.exist?(File.join(outside, 'fiasco'))
    end
  end

  def test_added_empty_directories_invalidate_the_snapshot
    with_inputs do |_root, _source, inputs, _record|
      FileUtils.mkdir_p(File.join(inputs.part('kernel'), 'unexpected-empty-directory'))
      assert_raises(Erx::Error) { inputs.verify }
    end
  end

  def test_linked_configuration_parent_is_not_a_source_root
    Dir.mktmpdir do |temporary|
      project = File.join(temporary, 'project')
      outside = File.join(temporary, 'outside')
      FileUtils.mkdir_p([File.join(project, 'fiasco'), File.join(outside, 'fiasco')])
      File.write(File.join(outside, 'fiasco/private-config'), 'outside data')
      File.symlink(outside, File.join(project, 'config'))
      error = assert_raises(Erx::Error) { Erx::FiascoInputs.new(root: project).prepare }
      assert_includes error.message, 'missing or linked Fiasco input directory: config/fiasco'
      refute File.exist?(File.join(project, 'build/fiasco/inputs'))
    end
  end

  def with_inputs
    Dir.mktmpdir('erx-inputs-') do |temporary|
      root = File.realpath(temporary)
      FileUtils.mkdir_p(File.join(root, 'fiasco/kernel/src'))
      FileUtils.mkdir_p(File.join(root, 'config/fiasco'))
      source = File.join(root, 'fiasco/kernel/src/banner.cpp')
      File.write(source, "// Modified by erXos\nint banner;\n")
      File.write(File.join(root, 'config/fiasco/kernel.defconfig'), 'CONFIG_ARM=y')
      FileUtils.mkdir_p([File.join(root, 'kernel/core'), File.join(root, 'include/erx/core'), File.join(root, 'liberx'),
                         File.join(root, 'build/gen/include/erx/core'), File.join(root, 'build/gen/kernel'),
                         File.join(root, 'build/gen/liberx')])
      File.write(File.join(root, 'kernel/core/watchdog.c'), "int watchdog;\n")
      File.write(File.join(root, 'include/erx/core/watchdog.h'), "extern int watchdog;\n")
      File.write(File.join(root, 'build/gen/include/erx/core/abi_trap.h'), "#define ERX_TRAP 1\n")
      inputs = Erx::FiascoInputs.new(root: root)
      record = inputs.prepare
      yield root, source, inputs, record
    end
  end

  def test_capture_is_read_only_and_records_the_bytes_that_were_copied
    with_inputs do |_root, source, inputs, record|
      captured = File.join(inputs.part('kernel'), 'src/banner.cpp')
      assert_equal File.binread(source), File.binread(captured)
      assert_equal 0, File.stat(captured).mode & 0o222
      assert_equal record, inputs.verify
      assert_equal record, inputs.prepare
    end
  end

  def test_verified_observations_read_only_the_captured_snapshot
    with_inputs do |root, source, inputs, _record|
      inputs.verify
      captured = File.join(inputs.part('kernel'), 'src/banner.cpp')
      bytes = inputs.read(captured)
      assert bytes.frozen?
      assert_equal Digest::SHA256.hexdigest(bytes), inputs.verified_hash(captured)
      assert_equal bytes.bytesize, inputs.observations.fetch('entries').fetch(captured).fetch('size')
      assert_raises(Erx::Error) { inputs.read(source) }
      assert_raises(Erx::Error) { inputs.authorize(File.join(root, 'unregistered')) }
    end
  end

  def test_repository_edit_keeps_old_capture_and_invalidates_the_record
    with_inputs do |_root, source, inputs, _record|
      captured = File.join(inputs.part('kernel'), 'src/banner.cpp')
      original = File.binread(captured)
      File.write(source, "// Modified by erXos\nint changed_banner;\n")
      assert_equal original, File.binread(captured)
      assert_raises(Erx::Error) { inputs.verify }
    end
  end

  def test_tampered_capture_is_rejected_instead_of_silently_recaptured
    with_inputs do |_root, _source, inputs, _record|
      captured = File.join(inputs.part('kernel'), 'src/banner.cpp')
      File.chmod(0o644, captured)
      File.write(captured, 'changed private source')
      assert_raises(Erx::Error) { inputs.verify }
      assert_raises(Erx::Error) { inputs.prepare }
    end
  end

  def test_a_later_build_captures_a_new_identity_for_repository_changes
    with_inputs do |_root, source, inputs, record|
      File.write(source, "// Modified by erXos\nint changed_banner;\n")
      changed = inputs.prepare
      refute_equal record.fetch('sha256'), changed.fetch('sha256')
      assert_equal changed, inputs.verify
    end
  end
  # The cores and their headers are the kernel's inputs alone: editing one
  # discards the kernel build's outputs and keeps the user build's.
  # The cores compile against the generated tree, so its headers are kernel inputs.
  def test_a_changed_generated_header_invalidates_the_kernel_build_alone
    with_inputs do |root, _source, inputs, record|
      File.write(File.join(root, 'build/gen/include/erx/core/abi_trap.h'), "#define ERX_TRAP 2\n")
      changed = inputs.prepare
      refute_equal inputs.component_id(record, component: 'kernel'), inputs.component_id(changed, component: 'kernel')
      assert_equal inputs.component_id(record, component: 'users'), inputs.component_id(changed, component: 'users')
      assert_equal "#define ERX_TRAP 2\n", File.read(inputs.path('build/gen/include/erx/core/abi_trap.h'))
    end
  end

  def test_a_changed_core_header_invalidates_the_kernel_build_alone
    with_inputs do |root, _source, inputs, record|
      File.write(File.join(root, 'include/erx/core/watchdog.h'), "extern long watchdog;\n")
      changed = inputs.prepare
      refute_equal inputs.component_id(record, component: 'kernel'), inputs.component_id(changed, component: 'kernel')
      assert_equal inputs.component_id(record, component: 'users'), inputs.component_id(changed, component: 'users')
      assert_equal "extern long watchdog;\n", File.read(inputs.path('include/erx/core/watchdog.h'))
    end
  end

  def test_a_changed_core_invalidates_the_kernel_build
    with_inputs do |root, _source, inputs, record|
      File.write(File.join(root, 'kernel/core/watchdog.c'), "int watchdog = 1;\n")
      refute_equal inputs.component_id(record, component: 'kernel'), inputs.component_id(inputs.prepare, component: 'kernel')
    end
  end
end
