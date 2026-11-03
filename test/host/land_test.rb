# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/land'

# Lands commits in a real scratch repository whose generator's one output
# holds the sorted source files, so two branches that each add a source
# conflict there and nowhere else.
class LandTest < Minitest::Test
  GENERATOR = <<~'RUBY'
    bytes = Dir.glob('src/*').sort.map { |path| File.read(path) }.join
    extra = File.file?('src/flag')
    if ARGV.first == '--check'
      exit(File.read('gen/out.txt') == bytes && File.file?('gen/only.out') == extra ? 0 : 1)
    end
    File.write('gen/out.txt', bytes)
    File.write('gen/only.out', "only\n") if extra
  RUBY

  def setup
    @directory = File.realpath(Dir.mktmpdir('erx-land-test-'))
    @root = File.join(@directory, 'tree')
    FileUtils.mkdir_p(File.join(@root, 'src'))
    FileUtils.mkdir_p(File.join(@root, 'gen'))
    @env = { 'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_SYSTEM' => File::NULL,
             'GIT_AUTHOR_NAME' => 'fixture', 'GIT_AUTHOR_EMAIL' => 'fixture@example.invalid',
             'GIT_COMMITTER_NAME' => 'fixture', 'GIT_COMMITTER_EMAIL' => 'fixture@example.invalid' }.freeze
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    File.write(File.join(@directory, 'generate.rb'), GENERATOR)
    git('init', '-q', '-b', 'main')
    write('src/base', "base\n")
    write('README', "start\n")
    generate
    commit('base')
    @land = Erx::Land.new(root: @root, runner: @runner, env: @env,
                          generator: [RbConfig.ruby, File.join(@directory, 'generate.rb')],
                          generated: ->(path) { path.start_with?('gen/') })
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_an_abi_output_is_told_from_a_source
    %w[include/erx/abi.h abi/generated.json tools/generated/abi.rb docs/generated/abi-reference.md
       kernel/generated/cap_slot_impl.h liberx/backend/erx/arch/aarch64/generated/calls.c].each do |path|
      assert Erx::Land.abi_output?(path), path
    end
    %w[abi/erx_abi.txt abi/arch/aarch64.txt include/erx/cap.h tools/lib/erx/abi.rb liberx/erx_lane.c
       kernel/core/cap.c TODO.md].each do |path|
      refute Erx::Land.abi_output?(path), path
    end
  end

  def test_a_clean_pick_is_picked
    other = branch('other') { add_source('other') }
    assert_equal :picked, @land.pick(other).state
    assert_equal "base\nother\n", read('gen/out.txt')
  end

  # The tool's own construction, with the generator and the outputs it owns.
  def test_by_default_a_conflict_in_a_source_stops_before_any_generator
    conflicting = branch('other') { add_source('theirs', readme: "their readme\n") }
    add_source('mine', readme: "my readme\n")
    outcome = Erx::Land.new(root: @root, runner: @runner, env: @env).pick(conflicting)
    assert_equal :stopped, outcome.state
    assert_equal ['README', 'gen/out.txt'], outcome.paths
  end

  def test_a_conflict_only_in_generated_outputs_is_regenerated_and_continued
    conflicting = both_add_a_source
    outcome = @land.pick(conflicting)
    assert_equal :regenerated, outcome.state
    assert_equal ['gen/out.txt'], outcome.paths
    assert_equal "base\nmine\ntheirs\n", read('gen/out.txt')
    refute File.exist?(File.join(@root, '.git/CHERRY_PICK_HEAD')), 'the pick is finished'
    assert_equal 'add theirs', git_output('log', '-1', '--format=%s').strip
    assert_empty git_output('status', '--porcelain')
  end

  def test_a_conflict_elsewhere_stops_with_the_pick_in_progress_and_the_files_listed
    conflicting = branch('other') do
      add_source('theirs', readme: "their readme\n")
    end
    add_source('mine', readme: "my readme\n")
    outcome = @land.pick(conflicting)
    assert_equal :stopped, outcome.state
    assert_equal ['README'], outcome.paths
    assert File.exist?(File.join(@root, '.git/CHERRY_PICK_HEAD')), 'the pick stays in progress'
    assert_includes read('README'), '<<<<<<<'

    # Still stopped until the file is resolved and added.
    assert_equal ['README'], @land.resume.paths

    write('README', "merged readme\n")
    git('add', 'README')
    assert_equal :regenerated, @land.resume.state
    assert_equal "base\nmine\ntheirs\n", read('gen/out.txt')
    assert_equal 'add theirs', git_output('log', '-1', '--format=%s').strip
  end

  # The picked commit drops an output the target changed: there is no side to
  # take, and the generator decides the output is gone.
  def test_an_output_the_commit_deletes_stays_deleted
    write('src/flag', "flag\n")
    generate
    commit('add the flag')
    conflicting = branch('other') do
      FileUtils.rm_f(File.join(@root, 'src/flag'))
      FileUtils.rm_f(File.join(@root, 'gen/only.out'))
      generate
      commit('drop the flag')
    end
    write('gen/only.out', "changed on main\n")
    commit('change the output')
    assert_equal :regenerated, @land.pick(conflicting).state
    refute File.exist?(File.join(@root, 'gen/only.out'))
    assert_equal 'drop the flag', git_output('log', '-1', '--format=%s').strip
    assert_empty git_output('status', '--porcelain')
  end

  def test_a_clean_pick_with_stale_outputs_is_regenerated_into_the_commit
    stale = branch('other') do
      write('src/forgot', "forgot\n")
      commit('add a source without generating')
    end
    assert_equal :refreshed, @land.pick(stale).state
    assert_equal "base\nforgot\n", read('gen/out.txt')
    assert_equal 'add a source without generating', git_output('log', '-1', '--format=%s').strip
    assert_empty git_output('status', '--porcelain')
    assert_includes git_output('show', '--name-only', '--format=', 'HEAD'), 'gen/out.txt'
  end

  # What is generated from must be what is committed.
  def test_an_edit_outside_the_index_is_refused
    conflicting = both_add_a_source
    write('README', "unstaged\n")
    error = assert_raises(Erx::Error) { @land.pick(conflicting) }
    assert_includes error.message, 'README'
    refute File.exist?(File.join(@root, '.git/CHERRY_PICK_HEAD')), 'nothing started'
    git('checkout', '--', 'README')

    assert_equal :stopped, stop_on_readme.state
    write('README', "merged\n")
    git('add', 'README')
    write('src/base', "edited after adding\n")
    error = assert_raises(Erx::Error) { @land.resume }
    assert_includes error.message, 'src/base'
    assert File.exist?(File.join(@root, '.git/CHERRY_PICK_HEAD')), 'the pick stays in progress'
  end

  def test_continuing_with_nothing_in_progress_is_an_error
    error = assert_raises(Erx::Error) { @land.resume }
    assert_includes error.message, 'no cherry-pick is in progress'
    assert_empty git_output('status', '--porcelain')
  end

  # The command takes one commit, since nothing would remember the rest across
  # a stop, and no range, which is many commits.
  def test_the_command_refuses_anything_but_one_commit
    tool = File.expand_path('../../tools/land', __dir__)
    [%w[a b], %w[a..b], %w[--continue a], [], ['-x']].each do |arguments|
      error = assert_raises(Erx::CommandError, arguments.join(' ')) do
        @runner.run([RbConfig.ruby, tool, *arguments], name: 'land-usage', deadline: 30, chdir: @root, env: @env)
      end
      assert_equal 2, error.result.fetch('exit_status'), arguments.join(' ')
    end
  end

  def test_a_pick_that_fails_with_no_conflict_is_an_error
    error = assert_raises(Erx::Error) { @land.pick('no-such-commit') }
    assert_includes error.message, 'failed with no conflict'
  end

  def test_a_failing_generator_leaves_the_pick_in_progress
    conflicting = both_add_a_source
    broken = Erx::Land.new(root: @root, runner: @runner, env: @env, generator: [RbConfig.ruby, '-e', 'exit 3'],
                           generated: ->(path) { path.start_with?('gen/') })
    assert_raises(Erx::CommandError) { broken.pick(conflicting) }
    assert File.exist?(File.join(@root, '.git/CHERRY_PICK_HEAD'))
  end

  private

  def stop_on_readme
    conflicting = branch('readme') { add_source('readme', readme: "their readme\n") }
    add_source('readme_mine', readme: "my readme\n")
    @land.pick(conflicting)
  end

  # Two commits that each add a source and so each change the output's last
  # line. Returns the other branch's commit, with main holding this one's.
  def both_add_a_source
    conflicting = branch('other') { add_source('theirs') }
    add_source('mine')
    conflicting
  end

  def branch(name)
    git('checkout', '-q', '-b', name)
    yield
    head = git_output('rev-parse', 'HEAD').strip
    git('checkout', '-q', 'main')
    head
  end

  def add_source(name, readme: nil)
    write("src/#{name}", "#{name}\n")
    write('README', readme) if readme
    generate
    commit("add #{name}")
  end

  def generate = @runner.run([RbConfig.ruby, File.join(@directory, 'generate.rb')], name: 'fixture', deadline: 30, chdir: @root)

  def commit(message)
    git('add', '--all')
    git('commit', '-q', '-m', message)
  end

  def write(path, text) = File.write(File.join(@root, path), text)

  def read(path) = File.read(File.join(@root, path))

  def git(*arguments) = @runner.run(['git', *arguments], name: 'fixture-git', deadline: 30, chdir: @root, env: @env)

  def git_output(*arguments) = File.read(git(*arguments).fetch('log'))
end
