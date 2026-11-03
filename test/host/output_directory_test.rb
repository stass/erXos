# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/output_directory'

class OutputDirectoryTest < Minitest::Test
  def test_whole_plan_check_creates_nothing_when_a_later_branch_is_linked
    Dir.mktmpdir do |temporary|
      project = File.join(temporary, 'project')
      outside = File.join(temporary, 'outside')
      FileUtils.mkdir_p([project, outside])
      File.symlink(outside, File.join(project, 'linked'))
      assert_raises(Erx::Error) do
        %w[valid/nested linked/nested].each { |path| Erx::OutputDirectory.check(root: project, path: path) }
      end
      refute File.exist?(File.join(project, 'valid'))
      assert_empty Dir.children(outside)
    end
  end
  def test_linked_build_is_refused_without_an_outside_write
    Dir.mktmpdir do |temporary|
      project = File.join(temporary, 'project')
      outside = File.join(temporary, 'outside')
      FileUtils.mkdir_p([project, outside])
      File.write(File.join(outside, 'sentinel'), 'unchanged')
      File.symlink(outside, File.join(project, 'build'))
      assert_raises(Erx::Error) { Erx::OutputDirectory.prepare(root: project, path: 'build/logs') }
      assert_equal ['sentinel'], Dir.children(outside)
      assert_equal 'unchanged', File.read(File.join(outside, 'sentinel'))
    end
  end

  def test_linked_deeper_branch_is_checked_before_creating_descendants
    Dir.mktmpdir do |temporary|
      project = File.join(temporary, 'project')
      outside = File.join(temporary, 'outside')
      FileUtils.mkdir_p([File.join(project, 'build'), outside])
      File.symlink(outside, File.join(project, 'build/fiasco'))
      assert_raises(Erx::Error) { Erx::OutputDirectory.prepare(root: project, path: 'build/fiasco/images') }
      assert_empty Dir.children(outside)
    end
  end

  def test_explicit_root_alias_and_contained_absolute_path_are_supported
    Dir.mktmpdir do |temporary|
      requested = File.join(temporary, 'logs/nested')
      actual = Erx::OutputDirectory.prepare(root: temporary, path: requested)
      assert_equal File.join(File.realpath(temporary), 'logs/nested'), actual
      assert File.directory?(actual)
    end
  end

  def test_escape_and_regular_file_ancestor_are_refused
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'file'), 'data')
      assert_raises(Erx::Error) { Erx::OutputDirectory.prepare(root: root, path: '../outside') }
      assert_raises(Erx::Error) { Erx::OutputDirectory.prepare(root: root, path: 'file/logs') }
    end
  end
end
