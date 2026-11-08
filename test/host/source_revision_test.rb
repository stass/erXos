# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/source_revision'

# The source revision a build records (Erx::SourceRevision): read from a
# scratch git checkout with a fixed commit date, so each case knows the
# answer; and the pure parse, which refuses an answer of the wrong shape.
class SourceRevisionTest < Minitest::Test
  SourceRevision = Erx::SourceRevision
  # 2026-11-08 18:42:33 UTC.
  COMMITTED = 1_794_163_353
  IDENTITY = { 'GIT_AUTHOR_NAME' => 'erXos test', 'GIT_AUTHOR_EMAIL' => 'test@example.invalid',
               'GIT_COMMITTER_NAME' => 'erXos test', 'GIT_COMMITTER_EMAIL' => 'test@example.invalid',
               'GIT_AUTHOR_DATE' => "#{COMMITTED} +0000", 'GIT_COMMITTER_DATE' => "#{COMMITTED} +0000",
               'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1' }.freeze

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-source-revision-'))
    @tree = File.join(@scratch, 'tree')
    @runner = Erx::Runner.new(owner_root: @scratch, log_dir: File.join(@scratch, 'logs'))
    FileUtils.mkdir_p(@tree)
  end

  def teardown
    FileUtils.remove_entry(@scratch) if @scratch
  end

  def git(*arguments)
    output, status = Open3.capture2e(IDENTITY, 'git', '-C', @tree, *arguments, in: File::NULL)
    raise "git #{arguments.join(' ')} failed: #{output}" unless status.success?

    output.chomp
  end

  def commit(text)
    File.write(File.join(@tree, 'file'), text)
    git('add', 'file')
    git('commit', '--quiet', '-m', text)
  end

  def checkout_of_two_commits
    git('init', '--quiet', '--initial-branch=main')
    commit('one')
    commit('two')
  end

  def read = SourceRevision.read(root: @tree, runner: @runner)

  def test_a_clean_branch_gives_the_branch_the_count_and_the_hash
    checkout_of_two_commits
    revision = read
    hash = git('rev-parse', '--short=12', 'HEAD')
    assert_equal ['main', 2, hash, false, Time.at(COMMITTED).utc],
                 [revision.branch, revision.count, revision.hash, revision.dirty, revision.committed_at]
    assert_equal "main-n2-#{hash}", revision.to_s
    assert_equal 12, revision.hash.size
  end

  def test_a_tracked_change_staged_or_not_marks_the_revision_dirty
    checkout_of_two_commits
    File.write(File.join(@tree, 'file'), 'three')
    assert read.dirty, 'an unstaged change'
    git('add', 'file')
    assert read.dirty, 'a staged change'
    assert_match(/-dirty\z/, read.to_s)
  end

  def test_an_untracked_file_leaves_the_revision_clean
    checkout_of_two_commits
    File.write(File.join(@tree, 'untracked'), 'x')
    refute read.dirty
  end

  def test_a_detached_head_leaves_the_branch_out_as_newvers_sh_does
    checkout_of_two_commits
    git('checkout', '--quiet', '--detach', 'HEAD~1')
    revision = read
    assert_nil revision.branch
    assert_equal "n1-#{git('rev-parse', '--short=12', 'HEAD')}", revision.to_s
  end

  def test_the_same_tree_reads_the_same_revision_twice
    checkout_of_two_commits
    File.write(File.join(@tree, 'file'), 'three')
    assert_equal read, read
  end

  def test_a_tree_that_is_not_a_checkout_has_no_revision
    assert_nil read
  end

  def answers(**changed)
    { commit: "0123456789abcdef0123456789abcdef01234567\n", shallow: "false\n", count: "7\n", branch: "main\n",
      committed: "#{COMMITTED}\n", changes: '' }.merge(changed)
  end

  def test_parse_reads_a_shallow_clone_without_its_count
    assert_equal 'main-0123456789ab', SourceRevision.parse(answers(shallow: "true\n")).to_s
  end

  def test_parse_refuses_an_answer_of_the_wrong_shape
    [{ commit: "main\n" }, { commit: "0123456789ab\n" }, { count: "-1\n" }, { branch: "evil\e]8;;\n" }, { branch: "caf\u00e9\n" },
     { branch: "a b\n" }, { committed: "soon\n" }, { shallow: "maybe\n" },
     { changes: "warning: could not open directory 'x/'\n" }].each do |changed|
      error = assert_raises(Erx::Error, changed.inspect) { SourceRevision.parse(answers(**changed)) }
      assert_includes error.message, changed.keys.first.to_s
    end
  end
end
