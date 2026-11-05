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

  # Stands in for every subprocess: rsync copies, the emulator's make leaves an
  # executable, lib_src's make compiles the copy's lib_src source, and each step's
  # name and argument vector are recorded.
  class RecordingRunner
    LIB_SRC_SOURCE = 'erts/lib_src/common/erl_misc_utils.c'
    LIB_SRC_STAMP = "erts/lib_src/obj/#{Erx::Runtime::TARGET}/opt/MADE".freeze

    attr_reader :steps, :argvs, :relinked, :lib_src_compiled

    def initialize(output) = (@output = output; @steps = []; @argvs = {})
    attr_accessor :fail_step, :link_leaves_nothing

    def run(argv, name:, **)
      @steps << name
      @argvs[name] = argv
      raise Erx::Error, "#{name} failed" if name == fail_step

      case name
      when 'runtime-copy' then FileUtils.cp_r("#{argv[-2]}.", argv[-1])
      when 'runtime-lib-src' then make_lib_src
      when 'runtime-emulator' then make_emulator
      end
    end

    private

    # lib_src's own makefile compiles what changed and touches its stamp.
    def make_lib_src
      @lib_src_compiled = File.read(File.join(@output.root, LIB_SRC_SOURCE))
      FileUtils.mkdir_p(File.dirname(File.join(@output.root, LIB_SRC_STAMP)))
      FileUtils.touch(File.join(@output.root, LIB_SRC_STAMP))
    end

    # As the emulator's makefile behaves: beam.smp is copied from beam.emu when beam.emu
    # exists, and an empty .SECONDARY makes a missing beam.emu no reason to link while
    # beam.smp exists. So only with both gone does a link happen. lib_src's archives it
    # names by their stamp, a target with no prerequisites, so it descends into lib_src
    # only while the stamp is missing.
    def make_emulator
      make_lib_src unless File.exist?(File.join(@output.root, LIB_SRC_STAMP))
      primary = File.join(File.dirname(@output.beam), 'beam.smp')
      @relinked = !File.exist?(@output.beam) && !File.exist?(primary)
      return if link_leaves_nothing

      FileUtils.mkdir_p(File.dirname(@output.beam))
      File.write(@output.beam, '') if @relinked
      FileUtils.cp(@output.beam, primary) unless File.exist?(primary)
    end
  end

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
    write_otp(RecordingRunner::LIB_SRC_SOURCE, 'stock')
    Runtime::LIBERX_SOURCES.each { |path| write_tree(path, 'stock') }
    @output = Runtime.output(root: @root)
    @runner = RecordingRunner.new(@output)
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

  # lib_src's archives (ethread, erts_internal) reach the emulator's link, but the
  # emulator's make looks at them only through a stamp it never remakes once made.
  def test_an_edit_under_lib_src_reaches_its_archives
    build
    write_otp(RecordingRunner::LIB_SRC_SOURCE, 'changed')
    build
    assert_equal 'changed', @runner.lib_src_compiled
    argv = @runner.argvs.fetch('runtime-lib-src')
    assert_equal ['-C', 'erts/lib_src', 'opt'], argv.each_cons(3).find { |window| window.first == '-C' }
    assert_includes argv, "TARGET=#{Runtime::TARGET}"
    assert_operator @runner.steps.index('runtime-lib-src'), :<, @runner.steps.index('runtime-emulator'),
                    "lib_src's archives must be current before the emulator links them"
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
