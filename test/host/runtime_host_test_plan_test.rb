# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runtime'

# Which host test files the check runs on each host: on macOS all of them, and
# elsewhere all but the hosted runtime's, which are named as not run.
class RuntimeHostTestPlanTest < Minitest::Test
  OTHER = 'test/host/test_pool_test.rb'

  def setup
    @root = Dir.mktmpdir('host-test-plan-')
    [*Erx::Runtime::HOSTED_ONLY_TESTS, OTHER].each { |path| write(path) }
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def write(path)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), '')
  end

  def paths = [OTHER, *Erx::Runtime::HOSTED_ONLY_TESTS].sort.map { |path| File.join(@root, path) }

  def plan(platform) = Erx::Runtime.host_test_plan(paths, root: @root, platform: platform)

  def test_macos_runs_every_file
    result = plan('arm64-darwin25')
    assert_equal paths, result.run
    assert_empty result.not_run
  end

  def test_freebsd_and_linux_name_the_hosted_files_as_not_run
    %w[amd64-freebsd16 x86_64-linux aarch64-linux].each do |platform|
      result = plan(platform)
      assert_equal [File.join(@root, OTHER)], result.run, platform
      assert_equal Erx::Runtime::HOSTED_ONLY_TESTS.sort.map { |path| File.join(@root, path) },
                   result.not_run.map(&:path), platform
      assert(result.not_run.all? { |entry| entry.reason == Erx::Runtime::HOST_RULE }, platform)
    end
  end

  def test_a_listed_file_that_is_gone_fails_the_plan
    FileUtils.rm_f(File.join(@root, Erx::Runtime::HOSTED_ONLY_TESTS.first))
    error = assert_raises(Erx::Error) { plan('amd64-freebsd16') }
    assert_includes error.message, Erx::Runtime::HOSTED_ONLY_TESTS.first
  end

  # The list names files of this tree, so a rename cannot leave a stale entry.
  def test_the_list_names_files_of_the_tree
    root = File.expand_path('../..', __dir__)
    Erx::Runtime::HOSTED_ONLY_TESTS.each { |path| assert_path_exists File.join(root, path) }
  end
end
