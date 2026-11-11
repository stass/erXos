# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require_relative '../../tools/lib/erx/setup'

class SetupTest < Minitest::Test
  LOCK = Erx::DependencySchema.parse(File.binread(File.expand_path('../../deps.lock', __dir__)))
  NAMES = Erx::Setup.steps(LOCK, hosted_runtime: true).map(&:name).freeze
  PINNED = LOCK.map { |source| source.fetch('id') }.freeze

  def everything(value) = NAMES.to_h { |name| [name, value] }

  def test_fresh_tree_runs_every_step_in_order
    assert_equal NAMES, Erx::Setup.plan({}, steps: Erx::Setup.steps(LOCK, hosted_runtime: true)).map(&:name)
    assert_equal NAMES.length - 6, NAMES.take_while { |name| name.start_with?('source-') }.length
    # The fetches come before the builds; the runtime build packs the hosted release,
    # whose EROFS image fsimg writes.
    assert_equal %w[web-store oracle-jit oracle-emu fsimg runtime rc-oracle], NAMES.last(6)
  end

  def test_a_host_without_the_hosted_runtime_leaves_out_only_its_step
    names = Erx::Setup.steps(LOCK, hosted_runtime: false).map(&:name)
    assert_equal NAMES - ['runtime'], names
  end

  def test_complete_tree_runs_nothing
    assert_empty Erx::Setup.plan(everything(true), steps: Erx::Setup.steps(LOCK, hosted_runtime: true))
  end

  def test_only_missing_steps_run
    present = everything(true).merge('source-musl' => false, 'runtime' => false)
    assert_equal %w[source-musl runtime], Erx::Setup.plan(present, steps: Erx::Setup.steps(LOCK, hosted_runtime: true)).map(&:name)
  end

  # Every pinned source is fetched by setup or skipped with its reason, and a
  # skip names a source deps.lock still pins.
  def test_every_pinned_source_is_fetched_or_skipped_with_a_reason
    fetched = NAMES.filter_map { |name| name.delete_prefix('source-') if name.start_with?('source-') }
    assert_equal PINNED.sort, (fetched + Erx::Setup::SKIPPED_SOURCES.keys).sort
    assert_empty fetched & Erx::Setup::SKIPPED_SOURCES.keys
    Erx::Setup::SKIPPED_SOURCES.each_value { |reason| refute_empty reason.strip }
  end

  # Setup obtains a source offline from a downloaded archive, which an OCI
  # image is not.
  def test_every_fetched_source_is_of_a_kind_setup_obtains_offline
    fetched = LOCK.reject { |source| Erx::Setup::SKIPPED_SOURCES.key?(source.fetch('id')) }
    assert_empty fetched.map { |source| source.fetch('kind') } - %w[tar zip git file]
  end

  # Only tools/erx sysreg refresh reads Arm's archive; make check never does.
  def test_arm_registers_is_not_a_step
    refute(NAMES.any? { |name| name.include?('arm-registers') })
  end

  def test_tla_tools_is_not_a_step
    refute(NAMES.any? { |name| name.include?('tla') })
  end

  def test_archive_directory_is_the_sibling_downloads_of_the_cache
    assert_equal '/x/build/downloads', Erx::Setup.archive_directory('/x/build/third_party')
  end

  def test_adopt_refuses_bytes_that_do_not_match_the_pin
    Dir.mktmpdir('erx-setup-') do |root|
      FileUtils.copy_file(File.expand_path('../../deps.lock', __dir__), File.join(root, 'deps.lock'))
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
      dependencies = Erx::Dependencies.new(root: root, runner: runner)
      bogus = File.join(root, 'bogus.tar.gz')
      File.binwrite(bogus, 'not the pinned bytes')
      assert_raises(Erx::Error) { dependencies.adopt('musl', from: bogus) }
      assert_empty Dir.glob(File.join(root, 'build/downloads/*.tar.gz'))
    end
  end
end

# The decisions of Setup that keep it off the network and keep it from trusting a
# stray marker or directory. The runner records each command and runs it for real.
class SetupDecisionsTest < Minitest::Test
  # Wraps a Runner and remembers the program of every command it ran.
  class RecordingRunner
    attr_reader :programs

    def initialize(runner)
      @runner = runner
      @programs = []
    end

    def run(argv, **options)
      @programs << File.basename(argv.first)
      @runner.run(argv, **options)
    end
  end

  def lock_with_sha(sha256, id: 'musl')
    text = File.read(File.expand_path('../../deps.lock', __dir__))
    lock = Erx::JsonInput.parse(text)
    lock.fetch('sources').find { |source| source['id'] == id }['sha256'] = sha256
    JSON.pretty_generate(lock)
  end

  # A tree whose deps.lock pins musl to the bytes of a tiny archive built here.
  def with_tree(id: 'musl', directory: 'musl-1.2.6')
    Dir.mktmpdir('erx-setup-') do |temporary|
      root = File.realpath(temporary)
      content = File.join(root, 'content')
      FileUtils.mkdir_p(File.join(content, directory))
      File.write(File.join(content, directory, 'hello.txt'), "hello\n")
      cache = File.join(root, 'other/build/downloads')
      FileUtils.mkdir_p(cache)
      sample = File.join(cache, 'sample.tar.gz')
      system('tar', '-czf', sample, '-C', content, directory, exception: true)
      sha256 = Digest::SHA256.file(sample).hexdigest
      File.write(File.join(root, 'deps.lock'), lock_with_sha(sha256, id: id))
      FileUtils.mkdir_p(File.join(root, 'build'))
      runner = RecordingRunner.new(Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')))
      yield root, runner, sample, sha256
    end
  end

  def setup_for(root, runner, cache: nil)
    Erx::Setup.new(root: root, runner: runner, cache: cache)
  end

  def marker_dir(root)
    File.join(root, 'build/third_party/musl').tap { |directory| FileUtils.mkdir_p(directory) }
  end

  def test_source_valid_accepts_only_its_own_marker
    with_tree do |root, runner, _sample, _sha|
      setup = setup_for(root, runner)
      refute setup.send(:source_valid?, 'musl')
      entry = setup.instance_variable_get(:@dependencies).sources.find { |source| source['id'] == 'musl' }
      marker = File.join(marker_dir(root), '.source.json')
      File.write(marker, JSON.pretty_generate(entry))
      assert setup.send(:source_valid?, 'musl')
      File.write(marker, JSON.pretty_generate(entry.merge('sha256' => '0' * 64)))
      refute setup.send(:source_valid?, 'musl'), 'a marker for other bytes'
      File.write(marker, '{ not json')
      refute setup.send(:source_valid?, 'musl'), 'an unparsable marker'
      File.delete(marker)
      File.write(File.join(root, 'real.json'), JSON.pretty_generate(entry))
      File.symlink(File.join(root, 'real.json'), marker)
      refute setup.send(:source_valid?, 'musl'), 'a symlink marker'
    end
  end

  # The rc oracle step is done only when the corpus test would accept the
  # build: built from deps.lock's plan9port by the current recipe.
  def test_rc_oracle_is_valid_only_when_built_from_the_pin_by_the_current_recipe
    Dir.mktmpdir('erx-setup-') do |temporary|
      root = File.realpath(temporary)
      FileUtils.copy_file(File.expand_path('../../deps.lock', __dir__), File.join(root, 'deps.lock'))
      setup = Erx::Setup.new(root: root)
      refute setup.send(:rc_oracle_valid?), 'no build'
      output = File.join(root, Erx::RcOracle::OUTPUT)
      FileUtils.mkdir_p(output)
      %w[rc rcmain].each do |name|
        File.write(File.join(output, name), '')
        File.chmod(0o755, File.join(output, name))
      end
      stamp = { 'source' => Erx::RcOracle.source_record(root: root), 'recipe' => Erx::RcOracle::Build::RECIPE }
      write_stamp = ->(value) { File.write(File.join(output, Erx::RcOracle::STAMP), JSON.generate(value)) }
      write_stamp.call(stamp.merge('recipe' => '0' * 64))
      refute setup.send(:rc_oracle_valid?), 'another recipe'
      write_stamp.call(stamp.merge('source' => stamp.fetch('source').merge('sha256' => '0' * 64)))
      refute setup.send(:rc_oracle_valid?), 'another pin'
      write_stamp.call(stamp)
      assert setup.send(:rc_oracle_valid?)
    end
  end

  # Answers `brew --prefix` with prefix, and records each command it is asked to run.
  class BrewRunner
    attr_reader :commands

    def initialize(directory, prefix)
      @log = File.join(directory, 'brew-prefix.log')
      @prefix = prefix
      @commands = []
    end

    def run(argv, **_options)
      @commands << argv
      raise Erx::CommandError, { 'state' => 'failed', 'log' => @log } unless @prefix

      File.write(@log, "#{@prefix}\n")
      { 'log' => @log }
    end
  end

  # The toolchain env Setup finds from env alone: no ports prefix, and PATH only when env names one.
  def toolchain_env(env, runner, ports_prefix: File.join(Dir.tmpdir, 'erx-no-ports'))
    Erx::Setup.new(root: File.expand_path('../..', __dir__), runner: runner, env: env, ports_prefix: ports_prefix)
              .send(:toolchain_env)
  end

  def homebrew_tree(directory)
    %w[opt/llvm/bin/clang bin/ld.lld].each do |tool|
      path = File.join(directory, tool)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
    end
    directory
  end

  def test_toolchain_defaults_follow_the_homebrew_prefix
    assert_equal({ 'ERX_CLANG' => '/opt/homebrew/opt/llvm/bin/clang', 'ERX_LLD' => '/opt/homebrew/bin/ld.lld' },
                 Erx::Setup.toolchain_defaults('/opt/homebrew'))
    assert_equal({ 'ERX_CLANG' => '/usr/local/opt/llvm/bin/clang', 'ERX_LLD' => '/usr/local/bin/ld.lld' },
                 Erx::Setup.toolchain_defaults('/usr/local'))
  end

  def test_toolchain_comes_from_homebrew_prefix_without_asking_brew
    Dir.mktmpdir('erx-brew-') do |directory|
      prefix = homebrew_tree(File.join(directory, 'prefix'))
      runner = BrewRunner.new(directory, '/elsewhere')
      assert_equal Erx::Setup.toolchain_defaults(prefix), toolchain_env({ 'HOMEBREW_PREFIX' => prefix }, runner)
      assert_empty runner.commands
    end
  end

  def test_toolchain_asks_brew_for_its_prefix_when_the_environment_does_not_say
    Dir.mktmpdir('erx-brew-') do |directory|
      prefix = homebrew_tree(File.join(directory, 'prefix'))
      runner = BrewRunner.new(directory, prefix)
      assert_equal Erx::Setup.toolchain_defaults(prefix), toolchain_env({}, runner)
      assert_equal [%w[brew --prefix]], runner.commands
    end
  end

  def test_chosen_tools_are_kept_and_only_the_unset_one_is_filled_in
    Dir.mktmpdir('erx-brew-') do |directory|
      prefix = homebrew_tree(File.join(directory, 'prefix'))
      runner = BrewRunner.new(directory, prefix)
      assert_empty toolchain_env({ 'ERX_CLANG' => '/my/clang', 'ERX_LLD' => '/my/ld.lld' }, runner)
      assert_empty runner.commands
      assert_equal({ 'ERX_LLD' => File.join(prefix, 'bin/ld.lld') },
                   toolchain_env({ 'ERX_CLANG' => '/my/clang', 'HOMEBREW_PREFIX' => prefix }, runner))
    end
  end

  def llvm_bin(directory)
    FileUtils.mkdir_p(directory)
    %w[clang ld.lld].each do |tool|
      File.write(File.join(directory, tool), "#!/bin/sh\n")
      File.chmod(0o755, File.join(directory, tool))
    end
    directory
  end

  # Without Homebrew, the newest FreeBSD port that has both tools is taken.
  def test_toolchain_comes_from_the_newest_complete_freebsd_port
    Dir.mktmpdir('erx-ports-') do |ports|
      llvm_bin(File.join(ports, 'llvm9/bin'))
      newest = llvm_bin(File.join(ports, 'llvm23/bin'))
      FileUtils.mkdir_p(File.join(ports, 'llvm24/bin'))
      FileUtils.mkdir_p(File.join(ports, 'llvm-devel/bin'))
      found = toolchain_env({}, BrewRunner.new(ports, nil), ports_prefix: ports)
      assert_equal({ 'ERX_CLANG' => File.join(newest, 'clang'), 'ERX_LLD' => File.join(newest, 'ld.lld') }, found)
    end
  end

  # Off macOS, clang and ld.lld on PATH are the last resort; on macOS PATH's clang is Apple's.
  def test_toolchain_comes_from_path_only_off_macos
    Dir.mktmpdir('erx-path-') do |directory|
      bin = llvm_bin(File.join(directory, 'bin'))
      env = { 'PATH' => "#{File.join(directory, 'empty')}:#{bin}" }
      if Erx::HostOs::MACOS
        assert_raises(Erx::Error) { toolchain_env(env, BrewRunner.new(directory, nil)) }
      else
        assert_equal({ 'ERX_CLANG' => File.join(bin, 'clang'), 'ERX_LLD' => File.join(bin, 'ld.lld') },
                     toolchain_env(env, BrewRunner.new(directory, nil)))
      end
    end
  end

  def test_a_missing_toolchain_is_reported_not_passed_over
    Dir.mktmpdir('erx-brew-') do |directory|
      error = assert_raises(Erx::Error) { toolchain_env({ 'HOMEBREW_PREFIX' => directory }, BrewRunner.new(directory, nil)) }
      assert_match(%r{set ERX_CLANG and ERX_LLD.*#{Regexp.escape(directory)}/opt/llvm/bin/clang}, error.message)
      error = assert_raises(Erx::Error) { toolchain_env({}, BrewRunner.new(directory, nil)) }
      assert_match(/set ERX_CLANG and ERX_LLD.*no Homebrew/, error.message)
    end
  end

  def test_a_prefix_that_is_not_one_absolute_directory_is_refused
    Dir.mktmpdir('erx-brew-') do |directory|
      ['relative/prefix', File.join(directory, 'absent')].each do |prefix|
        error = assert_raises(Erx::Error) { toolchain_env({ 'HOMEBREW_PREFIX' => prefix }, BrewRunner.new(directory, nil)) }
        assert_match(/HOMEBREW_PREFIX does not name/, error.message)
      end
      runner = BrewRunner.new(directory, "#{directory}\nWarning: something")
      error = assert_raises(Erx::Error) { toolchain_env({}, runner) }
      assert_match(/brew --prefix. does not name/, error.message)
    end
  end

  def test_leftovers_cleans_only_an_oracle_directory_without_a_build_record
    with_tree do |root, runner, _sample, _sha|
      setup = setup_for(root, runner)
      jit, emu = Erx::Setup::COMMAND_STEPS
      runtime = Erx::Setup::COMMAND_STEPS.find { |step| step.name == 'runtime' }
      assert_empty setup.send(:leftovers, jit), 'no directory'
      FileUtils.mkdir_p(File.join(root, 'build/oracle/jit'))
      assert_equal ['--clean'], setup.send(:leftovers, jit)
      assert_empty setup.send(:leftovers, emu), 'the other flavour'
      assert_empty setup.send(:leftovers, runtime), 'a step with no flavour'
      File.write(File.join(root, 'build/oracle/jit/build.json'), '{}')
      assert_empty setup.send(:leftovers, jit), 'a finished build'
    end
  end

  def test_oracle_steps_wait_as_long_as_the_oracle_build_does
    assert(Erx::Setup::COMMAND_STEPS.all? { |step| step.deadline >= 14_400 })
  end

  def test_a_missing_archive_is_an_error_and_never_a_download
    with_tree do |root, runner, _sample, _sha|
      error = assert_raises(Erx::Error) { setup_for(root, runner).send(:obtain_source, 'musl') }
      assert_match(/not downloaded/, error.message)
      assert_empty runner.programs
    end
  end

  def test_a_cache_without_the_archive_is_an_error_and_never_a_download
    with_tree do |root, runner, _sample, _sha|
      cache = File.join(root, 'empty/build/third_party')
      FileUtils.mkdir_p(File.join(root, 'empty/build/downloads'))
      error = assert_raises(Erx::Error) { setup_for(root, runner, cache: cache).send(:obtain_source, 'musl') }
      assert_match(/not found in ERX_SOURCE_CACHE/, error.message)
      assert_empty runner.programs
      assert_empty Dir.glob(File.join(root, 'build/downloads/*'))
    end
  end

  def test_a_cached_archive_is_adopted_and_unpacked_without_the_network
    with_tree do |root, runner, sample, sha|
      cache = File.join(root, 'other/build/third_party')
      File.rename(sample, File.join(root, 'other/build/downloads', "musl-#{sha}.tar.gz"))
      setup = setup_for(root, runner, cache: cache)
      setup.send(:obtain_source, 'musl')
      assert File.file?(File.join(root, 'build/downloads', "musl-#{sha}.tar.gz"))
      assert_equal "hello\n", File.read(File.join(root, 'build/third_party/musl/musl-1.2.6/hello.txt'))
      assert setup.send(:source_valid?, 'musl')
      refute_includes runner.programs, 'curl'
      refute_includes runner.programs, 'git'
    end
  end

  def test_a_cached_libc_test_archive_is_adopted_and_unpacked
    with_tree(id: 'libc-test', directory: 'libc-test-63e36e9') do |root, runner, sample, sha|
      File.rename(sample, File.join(root, 'other/build/downloads', "libc-test-#{sha}.tar.gz"))
      setup = setup_for(root, runner, cache: File.join(root, 'other/build/third_party'))
      setup.send(:obtain_source, 'libc-test')
      assert File.file?(File.join(root, 'build/downloads', "libc-test-#{sha}.tar.gz"))
      assert_equal "hello\n", File.read(File.join(root, 'build/third_party/libc-test/libc-test-63e36e9/hello.txt'))
      assert setup.send(:source_valid?, 'libc-test')
      refute_includes runner.programs, 'git'
    end
  end

  def test_adopt_keeps_matching_bytes_and_leaves_an_existing_archive_alone
    with_tree do |root, runner, sample, sha|
      dependencies = Erx::Dependencies.new(root: root, runner: runner)
      archive = dependencies.adopt('musl', from: sample)
      assert_equal File.join(root, 'build/downloads', "musl-#{sha}.tar.gz"), archive
      assert_equal sha, Digest::SHA256.file(archive).hexdigest
      assert_equal [archive], Dir.glob(File.join(root, 'build/downloads/*'))
      File.write(sample, 'other bytes')
      assert_equal archive, dependencies.adopt('musl', from: sample)
      assert_equal sha, Digest::SHA256.file(archive).hexdigest, 'an existing archive is not replaced'
    end
  end
end
