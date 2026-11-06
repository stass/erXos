# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runtime'

# What `tools/erx build runtime` decides, with OTP's configure and make replaced
# by a runner that records them. Each case is a way an edit could fail to reach
# the runtime while the build still says it built.
class RuntimeBuildTest < Minitest::Test
  Runtime = Erx::Runtime
  ErlangApps = Erx::ErlangApps

  # Stands in for every subprocess: rsync copies, the emulator's make leaves an
  # executable, xref of the serving set answers with serving_reached in its log, and
  # each step's name is recorded.
  class RecordingRunner
    attr_reader :steps, :relinked, :options
    attr_accessor :fail_step, :link_leaves_nothing, :serving_reached

    def initialize(output, log_dir:)
      @output = output
      @log_dir = log_dir
      @steps = []
      @options = {}
    end

    def run(argv, name:, **options)
      @steps << name
      @options[name] = options
      raise Erx::Error, "#{name} failed" if name == fail_step

      case name
      when 'runtime-copy' then FileUtils.cp_r("#{argv[-2]}.", argv[-1])
      when 'runtime-emulator' then make_emulator
      when 'serving-set' then serving_log
      end
    end

    private

    # As erl prints xref's answer: one line per module reached.
    def serving_log
      log = File.join(@log_dir, 'serving-set.log')
      FileUtils.mkdir_p(@log_dir)
      File.write(log, serving_reached.map { |name| "module #{name}\n" }.join)
      { 'log' => log }
    end

    # As the emulator's makefile behaves: beam.smp is copied from beam.emu when beam.emu
    # exists, and an empty .SECONDARY makes a missing beam.emu no reason to link while
    # beam.smp exists. So only with both gone does a link happen.
    def make_emulator
      primary = File.join(File.dirname(@output.beam), 'beam.smp')
      @relinked = !File.exist?(@output.beam) && !File.exist?(primary)
      return if link_leaves_nothing

      FileUtils.mkdir_p(File.dirname(@output.beam))
      File.write(@output.beam, '') if @relinked
      FileUtils.cp(@output.beam, primary) unless File.exist?(primary)
    end
  end

  # The checked-in serving list of the test tree.
  SERVING_LIST = %w[binary erx_fs erx_ramfs].freeze

  class FakeOracle
    def verify(_flavour) = {}
    def erl_path(_flavour) = '/nonexistent/bin/erl'
  end

  def setup
    skip 'the hosted runtime builds only on macOS' unless RUBY_PLATFORM.include?('darwin')

    @root = File.realpath(Dir.mktmpdir('erx-runtime-build-'))
    @sdk = '/sdk/one'
    %w[configure erts/configure make/configure erts/emulator/Makefile.in erts/config.h.in erts/autoconf/config.sub
       otp_only.c].each { |path| write_otp(path, 'stock') }
    write_otp(Runtime::XCOMP_FILE, 'stock')
    Runtime::LIBERX_SOURCES.each { |path| write_tree(path, 'stock') }
    # erXos's applications, each with its resource file and no modules but erx_files'
    # serving list: the build refuses a tree without them, and the recording runner
    # compiles nothing.
    ErlangApps::APPLICATIONS.each do |application|
      modules = application == 'erx_files' ? 'erx_ramfs_serving' : ''
      write_tree(File.join(ErlangApps.source(application), 'src', "#{application}.app.src"),
                 "{application, #{application}, [{modules, [#{modules}]}]}.\n")
    end
    write_tree(Erx::ServingSet::GENERATED, Erx::ServingSet.render(SERVING_LIST))
    write_otp('erts/preloaded/src/Makefile', "PRE_LOADED_ERL_MODULES = \\\n\tinit \\\n\terlang\n\n" \
                                              "PRE_LOADED_BEAM_MODULES = \\\n\tprim_eval\n")
    @output = Runtime.output(root: @root)
    @runner = RecordingRunner.new(@output, log_dir: File.join(@root, 'logs'))
    # What xref answers in a tree whose serving list is current: the list, preloaded
    # modules and the name of a fun call, which the check leaves out.
    @runner.serving_reached = [*SERVING_LIST, 'erlang', 'prim_eval', Erx::ServingSet::FUN_CALL].shuffle(random: Random.new(1))
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def write_tree(path, text)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def write_otp(path, text) = write_tree(File.join('otp', path), text)

  def build
    @runner.steps.clear
    Runtime.new(root: @root, runner: @runner, oracle: FakeOracle.new, sdk_root: @sdk).build
  end

  def configured? = @runner.steps.include?('runtime-configure')

  # The build reads xref's answer back from the step's log, so it runs as every other
  # step does, and refuses a serving list the beams have outgrown or left behind.
  def test_the_build_holds_the_serving_list_to_what_xref_reaches
    build
    assert_includes @runner.steps, 'serving-set'
    assert_equal Erx::Oracle::CLEAN_ERLANG_ENV, @runner.options.fetch('serving-set').fetch(:env)

    @runner.serving_reached += ['ets']
    error = assert_raises(Erx::Error) { build }
    assert_includes error.message, "is stale: missing ets; extra ; run"

    @runner.serving_reached -= %w[ets binary]
    error = assert_raises(Erx::Error) { build }
    assert_includes error.message, "is stale: missing ; extra binary; run"
  end

  def test_a_second_build_of_the_same_tree_does_not_configure_again
    build
    assert configured?
    build
    refute configured?
  end

  # The makefile make runs is configure's output, so an edit to a template reaches
  # the build only through configure.
  def test_every_template_of_configure_configures_again
    %w[erts/emulator/Makefile.in erts/config.h.in erts/autoconf/config.sub erts/configure].each do |path|
      build
      write_otp(path, "changed #{path}")
      build
      assert configured?, "#{path} changed and configure did not run"
    end
  end

  def test_the_cross_file_and_the_sdk_configure_again
    build
    write_otp(Runtime::XCOMP_FILE, 'changed')
    build
    assert configured?
    @sdk = '/sdk/two'
    build
    assert configured?
  end

  def test_a_source_edit_is_copied_without_configuring
    build
    write_otp('otp_only.c', 'changed')
    build
    refute configured?
    assert_equal 'changed', File.read(File.join(@output.root, 'otp_only.c'))
  end

  def test_a_file_that_left_otp_leaves_the_copy
    build
    FileUtils.rm(File.join(@root, 'otp/otp_only.c'))
    build
    refute_path_exists File.join(@output.root, 'otp_only.c')
  end

  # The archive reaches the link through LIBS, which is no make dependency.
  def test_each_build_relinks_so_liberx_reaches_the_executable
    build
    assert_path_exists @output.beam
    build
    assert_includes @runner.steps, 'runtime-emulator'
    assert @runner.relinked, 'the old executables would have satisfied make'
    assert_path_exists @output.beam
  end

  def test_a_link_that_leaves_no_executable_is_a_failed_build
    build
    @runner.link_leaves_nothing = true
    error = assert_raises(Erx::Error) { build }
    assert_match(/no #{Regexp.escape(@output.beam)}/, error.message)
    refute_path_exists Runtime.record_path(@output)
  end

  def test_a_copy_removed_by_hand_configures_again
    build
    FileUtils.rm_rf(@output.root)
    build
    assert configured?
  end

  def test_a_failed_configure_runs_again
    @runner.fail_step = 'runtime-configure'
    assert_raises(Erx::Error) { build }
    @runner.fail_step = nil
    build
    assert configured?
  end

  def test_the_record_says_whether_the_build_matches_the_tree
    assert_match(/not built/, assert_raises(Erx::Error) { Runtime.check_current(root: @root) }.message)
    build
    Runtime.check_current(root: @root)
    write_otp('otp_only.c', 'changed')
    assert_match(/stale/, assert_raises(Erx::Error) { Runtime.check_current(root: @root) }.message)
    build
    Runtime.check_current(root: @root)
    write_tree(Runtime::LIBERX_SOURCES.first, 'changed')
    assert_match(/stale/, assert_raises(Erx::Error) { Runtime.check_current(root: @root) }.message)
  end

  def test_a_failed_build_leaves_no_record
    build
    @runner.fail_step = 'runtime-emulator'
    assert_raises(Erx::Error) { build }
    assert_match(/not built/, assert_raises(Erx::Error) { Runtime.check_current(root: @root) }.message)
  end
end
