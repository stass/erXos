# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/private_state'
require_relative '../../tools/lib/erx/runner'

class ChecksTest < Minitest::Test
  PROJECT_ROOT = File.expand_path('../..', __dir__).freeze

  # Each test's project is a fresh git checkout; the runner's logs sit beside
  # it, outside the file set the check lists.
  def setup
    @directory = Dir.mktmpdir('erx-checks-')
    @root = File.join(@directory, 'project')
    Dir.mkdir(@root)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    git('init', '-q')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def git(*arguments)
    git_in(@root, *arguments)
  end

  # Fixture git commands get the same isolation as the check, so a caller's
  # GIT_DIR or GIT_INDEX_FILE never points them at a real repository.
  def git_in(directory, *arguments)
    @runner.run(['git', '-C', directory, *arguments], name: 'test-git', deadline: 30,
                env: Erx::Checks.isolated_git_environment)
  end

  # The fixture trees hold none of the tests the Elsewhere rules name, so
  # they are checked against the active chokepoint rules alone.
  def checks(imports: [], root: @root)
    Erx::Checks.new(root: root, runner: @runner, required_imports: imports,
                    chokepoints: Erx::ChokepointRules::ACTIVE)
  end

  # The source check runs the chokepoint rules over the git listing, so an
  # untracked but unignored file is checked as a tracked one is.
  def test_chokepoint_rules_run_over_listed_files
    write('kernel/core/a.c', "int value;\n")
    assert checks.run
    write('kernel/core/b.c', "#include <l4/sys/ipc.h>\n")
    error = assert_raises(Erx::Error) { checks.run }
    assert_match(%r{fiasco-headers-in-backend: kernel/core/b.c:1}, error.message)
  end

  def write(relative, bytes)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end

  def test_source_ascii_and_markdown_exemption
    write('source.c', "int value;\n")
    write('README.md', "prose \xc3\xa9\n".b)
    assert checks.run
    write('source.c', "/* \xc3\xa9 */\n".b)
    error = assert_raises(Erx::Error) { checks.run }
    assert_match(/source.c:1/, error.message)
  end

  def test_import_provenance_is_required
    assert_raises(Erx::Error) { checks(imports: ['missing']).run }
  end

  def test_imported_unicode_is_checked_against_its_baseline
    path = File.join(@root, 'import')
    source = write('import/source.c', "/* upstream \xc3\xa9 */\n".b)
    Erx::Origin.new(root: path).write(repository: 'https://example.org/source', revision: '1',
                                      archive_sha256: 'a' * 64,
                                      review: { 'default_license' => 'MIT',
                                                'default_evidence' => 'reviewed fixture', 'rules' => [] })
    assert checks(imports: ['import']).run
    File.binwrite(source, "int changed;\n")
    assert_raises(Erx::Error) { checks(imports: ['import']).run }
  end

  def test_host_tooling_parses_json_only_through_json_input
    write('tools/lib/erx/json_input.rb', "value = JSON.parse(text)\n")
    write('tools/lib/erx/writer.rb',
          "text = JSON.generate(value)\ntext = JSON . pretty_generate(value)\n" \
          "error = JsonInput::Unsupported\n# reads JSON: never through a raw parser\n")
    write('tools/notes.txt', "JSON.parse is documented here\n")
    assert checks.run
    { 'tools/lib/erx/reader.rb' => "# reader\nvalue = JSON.parse(text)\n",
      'tools/erx' => "#!/usr/bin/env ruby\nvalue = ::JSON.load(text)\n",
      'tools/fuzz/target.rb' => "value = JSON::Parser.new(text).parse\n",
      'tools/lib/erx/coder.rb' => "value = JSON::Coder.new.load(text)\n",
      'tools/lib/erx/restore.rb' => "value = JSON.restore(text)\n",
      'tools/lib/erx/rescue.rb' => "rescue JSON::ParserError\n",
      'tools/lib/erx/kernel.rb' => "value = JSON(text)\n",
      'tools/lib/erx/index.rb' => "value = JSON[text]\n",
      'tools/lib/erx/addition.rb' => "value = String.from_json(text)\n" }.each do |relative, source|
      path = write(relative, source)
      error = assert_raises(Erx::Error) { checks.run }
      assert_equal 'JSON used other than to write, outside tools/lib/erx/json_input.rb: ' \
                   "#{relative}:#{source.lines.size}", error.message
      File.unlink(path)
    end
  end

  def test_ignored_files_and_agent_worktrees_are_not_source_inputs
    write('.gitignore', "/build/\n/.claude/\n")
    write('build/fiasco/inputs/uart.h', "/* \xc3\xa9 */\n".b)
    worktree = File.join(@root, '.claude/worktrees/x')
    write('.claude/worktrees/x/build/state.rb', "\xff".b)
    git_in(@directory, 'init', '-q', worktree)
    write('.claude/worktrees/x/kernel.c', "/* \xc3\xa9 */\n".b)
    assert checks.run
  end

  def test_untracked_files_that_are_not_ignored_are_source_inputs
    write('.gitignore', "/build/\n")
    write('stray.c', "/* \xc3\xa9 */\n".b)
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'non-ASCII erXos source: stray.c:1', error.message
  end

  def test_tracked_files_are_source_inputs_even_when_ignored
    write('kernel/entry.c', "/* \xc3\xa9 */\n".b)
    git('add', 'kernel/entry.c')
    write('.gitignore', "/kernel/\n")
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'non-ASCII erXos source: kernel/entry.c:1', error.message
  end

  def test_a_tracked_file_deleted_from_the_checkout_has_nothing_to_check
    write('gone.c', "int gone;\n")
    git('add', 'gone.c')
    File.unlink(File.join(@root, 'gone.c'))
    assert checks.run
  end

  def test_nested_repository_that_is_not_ignored_is_refused
    nested = File.join(@root, 'vendor/clone')
    FileUtils.mkdir_p(nested)
    git_in(@directory, 'init', '-q', nested)
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'listed directory (a nested repository, a submodule, or a tracked file replaced by a directory) ' \
                 'is unsupported in the source tree: vendor/clone', error.message
  end

  # The case agent worktrees create: a linked worktree, whose .git is a file,
  # checks its own tracked files, and the main checkout that holds it under
  # the ignored .claude/ does not read them.
  def test_linked_worktree_checks_its_own_files
    write('.gitignore', "/.claude/\n")
    write('kernel.c', "int kernel;\n")
    git('add', '.gitignore', 'kernel.c')
    git('-c', 'user.name=erx', '-c', 'user.email=erx@example.org', 'commit', '-q', '-m', 'fixture')
    worktree = File.join(@root, '.claude/worktrees/x')
    git('worktree', 'add', '-q', worktree)
    assert File.file?(File.join(worktree, '.git'))
    assert checks(root: worktree).run
    File.binwrite(File.join(worktree, 'kernel.c'), "/* \xc3\xa9 */\n".b)
    error = assert_raises(Erx::Error) { checks(root: worktree).run }
    assert_equal 'non-ASCII erXos source: kernel.c:1', error.message
    assert checks.run
  end

  def test_project_outside_a_git_checkout_is_refused
    plain = File.join(@directory, 'plain')
    Dir.mkdir(plain)
    File.binwrite(File.join(plain, 'source.c'), "int value;\n")
    error = assert_raises(Erx::Error) { checks(root: plain).run }
    assert_match(/\Athe source check lists its files with git, and .* is not the top of a git checkout\z/,
                 error.message)
  end

  def test_project_below_another_checkout_is_refused
    inner = File.join(@root, 'inner')
    write('inner/source.c', "int value;\n")
    error = assert_raises(Erx::Error) { checks(root: inner).run }
    assert_match(/is not the top of a git checkout\z/, error.message)
  end

  def test_listing_parse_refuses_anything_but_nul_terminated_printable_names
    assert_equal %w[a b], Erx::Checks.listed_names("b\0a\0a\0".b, log: 'log')
    assert_equal ["\u00e9.c"], Erx::Checks.listed_names("\xc3\xa9.c\0".b, log: 'log')
    error = assert_raises(Erx::Error) { Erx::Checks.listed_names(''.b, log: 'log') }
    assert_equal 'git listed no project files; log: log', error.message
    ["a\0warning: could not open directory 'x/'\n".b, "a\0b".b, "a\0\0b\0".b, "warning: x\nb\0".b,
     "\xff\0".b, "a\x1b[31m\0".b].each do |bytes|
      error = assert_raises(Erx::Error) { Erx::Checks.listed_names(bytes, log: 'log') }
      assert_match(/\Agit reported a problem while listing sources/, error.message)
    end
  end

  def test_git_warning_about_a_skipped_directory_fails_the_check
    skip 'root reads a mode 000 directory, so git skips nothing' if Process.euid.zero?
    write('locked/hidden.c', "/* \xc3\xa9 */\n".b)
    write('visible.c', "int visible;\n")
    File.chmod(0o000, File.join(@root, 'locked'))
    error = assert_raises(Erx::Error) { checks.run }
    assert_match(/\Agit reported a problem while listing sources/, error.message)
  ensure
    File.chmod(0o755, File.join(@root, 'locked'))
  end

  def test_listing_starts_no_configured_monitor_program
    marker = File.join(@directory, 'monitor-ran')
    monitor = File.join(@directory, 'monitor')
    File.write(monitor, "#!/bin/sh\ntouch '#{marker}'\nexit 1\n")
    File.chmod(0o755, monitor)
    write('kernel.c', "int kernel;\n")
    git('add', 'kernel.c')
    git('config', 'core.fsmonitor', monitor)
    assert checks.run
    refute File.exist?(marker)
  end

  def test_git_environment_of_the_caller_does_not_shrink_the_listing
    write('kernel/entry.c', "/* \xc3\xa9 */\n".b)
    git('add', 'kernel/entry.c')
    write('.gitignore', "/kernel/\n")
    saved = ENV.to_h.slice('GIT_INDEX_FILE', 'GIT_DIR')
    ENV['GIT_INDEX_FILE'] = File.join(@directory, 'missing-index')
    ENV['GIT_DIR'] = File.join(@directory, 'missing-repository')
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'non-ASCII erXos source: kernel/entry.c:1', error.message
  ensure
    %w[GIT_INDEX_FILE GIT_DIR].each { |key| ENV[key] = saved[key] }
  end

  def test_source_links_must_reach_listed_files_inside_the_project
    write('real.c', "int real;\n")
    File.symlink('real.c', File.join(@root, 'alias.c'))
    assert checks.run
    File.binwrite(File.join(@directory, 'outside.c'), "int outside;\n")
    File.symlink(File.join(@directory, 'outside.c'), File.join(@root, 'leaves.c'))
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'source link leaves the project: leaves.c', error.message
    File.unlink(File.join(@root, 'leaves.c'))
    write('.gitignore', "/build/\n")
    write('build/output.c', "int output;\n")
    File.symlink('build/output.c', File.join(@root, 'output.c'))
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'source link names no listed project file: output.c', error.message
  end

  def test_source_directory_links_are_refused
    write('real/source.c', "int real;\n")
    File.symlink('real', File.join(@root, 'alias'))
    error = assert_raises(Erx::Error) { checks.run }
    assert_equal 'own source directory aliases are unsupported: alias', error.message
  end

  def test_tracked_file_reached_through_a_directory_link_is_refused
    write('kernel/entry.c', "int entry;\n")
    git('add', 'kernel/entry.c')
    write('.gitignore', "/kernel\n")
    FileUtils.mv(File.join(@root, 'kernel'), File.join(@directory, 'elsewhere'))
    File.symlink(File.join(@directory, 'elsewhere'), File.join(@root, 'kernel'))
    error = assert_raises(Erx::Error) { checks.run }
    assert_match(/\Aown source directory aliases are unsupported: kernel\z/, error.message)
  end

  # Private state is never a source: every private directory but .git is
  # ignored wherever it appears.
  def test_the_project_ignores_build_output_and_private_state
    ignored = File.readlines(File.join(PROJECT_ROOT, '.gitignore'), chomp: true)
    expected = ['/build/'] + (Erx::PrivateState::DIRECTORY_NAMES - ['.git']).map { |name| "#{name}/" }
    assert_empty expected - ignored
  end
end
