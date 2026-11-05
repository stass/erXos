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
  # executable, and each step's name is recorded.
  class RecordingRunner
    attr_reader :steps, :beam_present_at_link

    def initialize(output) = (@output = output; @steps = [])
    attr_accessor :fail_step

    def run(argv, name:, **)
      @steps << name
      raise Erx::Error, "#{name} failed" if name == fail_step

      case name
      when 'runtime-copy' then FileUtils.cp_r("#{argv[-2]}.", argv[-1])
      when 'runtime-emulator'
        @beam_present_at_link = File.exist?(@output.beam)
        FileUtils.mkdir_p(File.dirname(@output.beam))
        File.write(@output.beam, '')
      end
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
    refute @runner.beam_present_at_link, 'the old executable would have satisfied make'
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
