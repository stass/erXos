# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/private_state'

class PrivateStateTest < Minitest::Test
  def setup
    @directory = File.realpath(Dir.mktmpdir('erx-private-'))
    @root = File.join(@directory, '.claude/worktrees/x')
    FileUtils.mkdir_p(@root)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def inside?(path) = Erx::PrivateState.inside?(path, project_root: @root)

  def test_inside_the_project_only_components_below_the_root_count
    refute inside?(@root)
    refute inside?(File.join(@root, 'kernel/entry.c'))
    Erx::PrivateState::DIRECTORY_NAMES.each do |name|
      assert inside?(File.join(@root, name, 'file')), name
      assert inside?(File.join(@root, 'include', name, 'file')), name
    end
  end

  def test_outside_the_project_every_component_counts
    assert inside?(File.join(@directory, '.claude/worktrees/y/file'))
    refute inside?(File.join(@directory, 'file'))
    assert inside?('/home/user/.ssh/id')
    refute inside?('/Library/Developer/SDKs/SDKSettings.json')
  end

  def test_a_path_that_does_not_say_where_it_leads_is_refused
    ['relative/file', File.join(@root, '../../settings.json'), File.join(@root, './file'),
     "#{@root}//file", "#{@root}/"].each do |path|
      assert_raises(Erx::Error) { inside?(path) }
    end
  end
end
