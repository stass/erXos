# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/origin'
require_relative '../../tools/lib/erx/runtime'

# What `tools/erx build runtime` decides, with OTP's configure and make replaced
# by a runner that records them. Each case is a way an edit could fail to reach
# the runtime while the build still says it built.
class RuntimeBuildTest < Minitest::Test
  Runtime = Erx::Runtime
  ErlangApps = Erx::ErlangApps

  # Stands in for every subprocess: rsync copies with file times, as -a does, the
  # emulator's make leaves an executable, xref of the serving set answers with
  # serving_reached in its log, and each step's name is recorded.
  class RecordingRunner
    # The directories each application's make ran in, in order, those whose ../ebin
    # was missing when it ran, and the preloaded sources the copy held when the
    # preloaded make ran.
    attr_reader :steps, :relinked, :options, :directories, :missing_ebins, :argvs, :preloaded_sources
    attr_accessor :fail_step, :link_leaves_nothing, :serving_reached

    def initialize(output, log_dir:)
      @output = output
      @log_dir = log_dir
      @steps = []
      @options = {}
      @directories = []
      @missing_ebins = []
      @argvs = {}
    end

    def run(argv, name:, **options)
      @steps << name
      @options[name] = options
      @argvs[name] = argv
      record_application(argv[argv.index('-C') + 1]) if argv.first == 'gmake' &&
                                                            !%w[runtime-emulator runtime-preloaded].include?(name)
      raise Erx::Error, "#{name} failed" if name == fail_step

      case name
      when 'runtime-copy', 'runtime-copy-generated' then FileUtils.cp_r("#{argv[-2]}.", argv[-1], preserve: true)
      when 'runtime-preloaded' then @preloaded_sources = Dir.glob('*.erl', base: File.join(@output.root, 'erts/preloaded/src')).sort
      when 'runtime-emulator' then make_emulator
      when 'serving-set' then serving_log
      end
    end

    private

    def record_application(directory)
      @directories << directory
      @missing_ebins << directory unless File.directory?(File.join(@output.root, File.dirname(directory), 'ebin'))
    end

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

  # Stands in for Erx::Generated: ensure makes build/gen hold exactly files, paths
  # relative to it, and a stamp naming stamp_code, and counts its calls.
  class FakeGenerated
    attr_accessor :files, :stamp_code
    attr_reader :calls

    def initialize
      @files = {}
      @stamp_code = 'one'
      @calls = 0
    end

    def ensure(root:)
      @calls += 1
      output = File.join(root, Erx::Generated::OUTPUT)
      FileUtils.rm_rf(output)
      files.merge(Erx::Generated::STAMP => stamp_code).each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(output, path)))
        File.write(File.join(output, path), text)
      end
    end
  end

  GRAMMAR = 'erts/preloaded/src/erx_9p_grammar.erl'
  # The checkout itself, whose emulator and preloaded makefiles one case reads.
  TREE = File.expand_path('../..', __dir__)

  def setup
    skip 'the hosted runtime builds only on macOS' unless RUBY_PLATFORM.include?('darwin')

    @root = File.realpath(Dir.mktmpdir('erx-runtime-build-'))
    @sdk = '/sdk/one'
    %w[configure erts/configure make/configure erts/emulator/Makefile.in erts/config.h.in erts/autoconf/config.sub
       otp_only.c OTP_VERSION].each { |path| write_otp(path, 'stock') }
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
    @generated = FakeGenerated.new
    @generated.files = { File.join('otp', GRAMMAR) => 'generated' }
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
    Runtime.new(root: @root, runner: @runner, oracle: FakeOracle.new, sdk_root: @sdk, generated: @generated).build
  end

  def check_current = Runtime.check_current(root: @root, generated: @generated)

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

  # design-runtime.md keeps runtime_tools, so dbg is built with kernel, stdlib and
  # compiler; only its Erlang is, since its c_src holds drivers the design does not ship.
  def test_the_build_makes_runtime_tools_erlang_only
    build
    assert_includes @runner.steps, 'runtime-runtime_tools'
    assert_equal %w[kernel stdlib compiler runtime_tools].map { |application| "lib/#{application}/src" },
                 @runner.directories
  end

  # An application's make writes into ../ebin without creating it, and otp/ tracks none.
  def test_each_application_make_finds_its_ebin
    build
    assert_empty @runner.missing_ebins
  end

  # The emulator embeds the preloaded modules, so their own make compiles them before
  # the emulator's make runs, from a copy that already holds the generated grammar.
  def test_the_preloaded_modules_are_compiled_before_the_emulator_embeds_them
    build
    assert_equal ['gmake', '-j4', '-C', 'erts/preloaded/src', 'opt', "TARGET=#{Runtime::TARGET}"],
                 @runner.argvs.fetch('runtime-preloaded')
    assert_operator @runner.steps.index('runtime-preloaded'), :<, @runner.steps.index('runtime-emulator')
    assert_includes @runner.preloaded_sources, File.basename(GRAMMAR)
  end

  # Every beam the emulator embeds is one the preloaded make compiles, in the tree
  # itself: PRELOAD_BEAM names the preloaded Makefile's modules in erts/ebin, that
  # Makefile's EBIN, and nothing else. So a grammar change reaches a rebuilt runtime,
  # and with erts/ebin kept out of the copy (the next two cases) nothing else is embedded.
  def test_the_emulator_embeds_exactly_what_the_preloaded_make_compiles
    otp = File.join(TREE, 'otp')
    embedded = File.read(File.join(otp, 'erts/emulator/Makefile.in'))[/^PRELOAD_BEAM =((?:.*\\\n)*.*\n)/, 1]
    assert_equal '../../ebin', File.read(File.join(otp, 'erts/preloaded/src/Makefile'))[/^EBIN=(.*)$/, 1]
    assert_equal Erx::ServingSet.preloaded(root: TREE).map { |name| "$(ERL_TOP)/erts/ebin/#{name}.beam" }.sort,
                 embedded.split.reject { |word| word == '\\' }.sort
  end

  # A beam in the copy could stay newer than its source, and make would keep it over a
  # source edit, embed it or ship it. So otp/ORIGIN.md lists every directory of the
  # build's beams and boot scripts among its exclusions, and make check's origin check
  # refuses any file under one.
  def test_the_origin_record_excludes_every_build_output_directory
    excluded = Erx::Origin.new(root: File.join(TREE, 'otp')).inventory.fetch('exclusions').map { |entry| entry.fetch('path') }
    assert_empty Runtime::BUILD_OUTPUTS - excluded
    assert_includes Runtime::BUILD_OUTPUTS, 'erts/ebin'
  end

  # The copy takes nothing from those directories either, so a stray file there, such as
  # the output of a make run inside otp/, never reaches the build.
  def test_the_copy_takes_nothing_from_a_build_output_directory
    build
    assert_equal Runtime::BUILD_OUTPUTS.map { |path| "--exclude=/#{path}/" },
                 @runner.argvs.fetch('runtime-copy').grep(/\A--exclude=/)
  end

  def test_a_second_build_of_the_same_tree_does_not_configure_again
    build
    assert configured?
    build
    refute configured?
  end

  # The makefile make runs is configure's output, so an edit to what configure reads
  # reaches the build only through configure.
  def test_every_template_of_configure_configures_again
    %w[erts/emulator/Makefile.in erts/config.h.in erts/autoconf/config.sub erts/configure OTP_VERSION].each do |path|
      build
      write_otp(path, "changed #{path}")
      build
      assert configured?, "#{path} changed and configure did not run"
    end
  end

  # OTP's makefiles ask for configure again when a template is newer than the makefile
  # configure made from it, and the copy carries otp/'s file times. A checkout that
  # writes a template again with the same bytes, as a rebase does, leaves the stamp
  # alone, so the configured copy stays, and its templates must stay older than what
  # configure wrote. A time ahead of the clock stands in for the checkout.
  def test_a_template_written_again_with_the_same_bytes_stays_older_than_configure
    later = Time.now + 3600
    FileUtils.touch(File.join(@root, 'otp/erts/config.h.in'), mtime: later)
    build
    assert configured?
    FileUtils.touch(File.join(@root, 'otp/erts/emulator/Makefile.in'), mtime: later)
    build
    refute configured?
    configured_at = File.mtime(File.join(@output.root, '.erx-configured'))
    %w[erts/config.h.in erts/emulator/Makefile.in].each do |path|
      assert_operator File.mtime(File.join(@output.root, path)), :<, configured_at, "make would ask to configure #{path} again"
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
    assert_match(/not built/, assert_raises(Erx::Error) { check_current }.message)
    build
    check_current
    write_otp('otp_only.c', 'changed')
    assert_match(/stale/, assert_raises(Erx::Error) { check_current }.message)
    build
    check_current
    write_tree(Runtime::LIBERX_SOURCES.first, 'changed')
    assert_match(/stale/, assert_raises(Erx::Error) { check_current }.message)
  end

  # The generated tree's otp/ joins otp/'s copy, and the generated tree is
  # current before anything reads it.
  def test_the_generated_otp_files_join_the_copy
    build
    assert_operator @generated.calls, :>=, 1
    assert_equal 'generated', File.read(File.join(@output.root, GRAMMAR))
  end

  def test_a_file_that_left_the_generated_tree_leaves_the_copy
    build
    @generated.files = { File.join('otp', 'erts/preloaded/src/other.erl') => 'generated' }
    build
    refute_path_exists File.join(@output.root, GRAMMAR)
  end

  # OTP's makefiles and the cross file read the generated headers through ERX_GEN.
  def test_configure_and_make_see_the_generated_tree
    build
    %w[runtime-configure runtime-preloaded runtime-emulator runtime-kernel].each do |step|
      assert_equal File.join(@root, Erx::Generated::OUTPUT), @runner.options.fetch(step).fetch(:env).fetch('ERX_GEN'), step
    end
  end

  # A generator's input changing changes what ensure writes, which marks the build
  # stale; a stamp naming other generator code over the same files does not.
  def test_the_record_covers_the_generated_tree_but_not_its_stamp
    build
    @generated.stamp_code = 'two'
    check_current
    @generated.files = { File.join('otp', GRAMMAR) => 'regenerated' }
    assert_match(/stale/, assert_raises(Erx::Error) { check_current }.message)
  end

  def test_a_failed_build_leaves_no_record
    build
    @runner.fail_step = 'runtime-emulator'
    assert_raises(Erx::Error) { build }
    assert_match(/not built/, assert_raises(Erx::Error) { check_current }.message)
  end
end
