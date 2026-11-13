# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/lvgl'
require_relative '../../tools/lib/erx/origin'

# erx-lvgl end to end on the host (docs/design-display.md, "The widget
# server"): the program, built from LVGL's submodule under ASan and UBSan, is run
# by the model screen test/erlang/erx_lvgl_screen.erl on stock's emulator
# (ERX_ERL and ERX_ERLC), which encodes the server's records with the
# generated erx_ui_wire and reads the program's reports and events with it;
# it starts the program through test/fixtures/erx_lvgl_buffer.rb, which hands
# it the window's buffer, a file in the test's directory, as descriptor 3.
# The model screen says what it checks.
class ErxLvglTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  LAUNCHER = File.join(ROOT, 'test/fixtures/erx_lvgl_buffer.rb')
# The applications the model screen runs against, compiled whole (ErlangBuild):
# erx_ui holds the model of the widget tree and the generated erx_ui_wire, and erx is
# its dependency. Then the screen.
APPLICATIONS = %w[erx erx_ui].freeze
TESTS = %w[test/erlang/erx_lvgl_screen.erl].freeze

  def test_model_screen_drives_the_program
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-lvgl-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      %w[x8r8g8b8 r5g6b5].each do |channel|
        output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "io:format(\"~p~n\", [erx_lvgl_screen:run(#{screen(program)}, #{channel})]), halt(0)",
                      chdir: work)
        assert_match(/events => \[\{event,3,on_click,none\}\]/, output, channel)
        # Each report left unread across a resize names the size it was drawn at and is dropped.
        assert_match(/stale => \[\{120,80\},\{60,40\}\]/, output, channel)
        # A report open across a resize is still presented at the size it was drawn at.
        assert_match(/open_resize => \{240,160\}/, output, channel)
      end
      { short_buffer: /does not fit the window's buffer/, stray_presented: /answers no damage report/ }.each do |name, said|
        output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "io:format(\"status ~p~n\", [erx_lvgl_screen:refused(#{screen(program)}, #{name})]), halt(0)",
                      chdir: work)
        assert_match(/^status 1$/, output, name)
        assert_match(said, output, name)
      end
    end
  end

  private

  # The model screen's map of the program and how to start it, as an Erlang term.
  def screen(program)
    pairs = { program: program, ruby: RbConfig.ruby, launcher: LAUNCHER }.map { |key, path| "#{key} => #{path.inspect}" }
    "\#{#{pairs.join(', ')}}"
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end

# How the build treats the LVGL submodule's checkout: a missing one is
# refused with the command that fetches it, and git's status of one that has
# moved or changed is reported.
class LvglSubmoduleTest < Minitest::Test
  def test_a_missing_checkout_names_the_command_that_fetches_it
    Dir.mktmpdir('erx-lvgl-submodule') do |root|
      error = assert_raises(Erx::Error) { Erx::Lvgl.source_tree(root: root, runner: nil) }
      assert_equal 'LVGL is not checked out at display/lvgl/lvgl; run ' \
                   '`git submodule update --init display/lvgl/lvgl`', error.message
    end
  end

  def test_init_leaves_a_checkout_that_is_there_and_says_so
    Dir.mktmpdir('erx-lvgl-submodule') do |root|
      FileUtils.mkdir_p(File.join(root, Erx::Lvgl::SUBMODULE))
      File.write(File.join(root, Erx::Lvgl::SUBMODULE, 'lvgl.h'), '')
      assert_equal 'LVGL: display/lvgl/lvgl is already checked out; left as it is',
                   Erx::Lvgl.init(root: root, runner: nil)
    end
  end

  # Lines as `git status --porcelain=v2 --ignore-submodules=none
  # --untracked-files=normal` prints them for the submodule: `1 XY S<c><m><u>
  # mH mI mW hH hI path`, or `u XY S... m1 m2 m3 mW h1 h2 h3 path`.
  PINNED = '80ca777e' + ('0' * 32)
  BUMPED = '1f2e3d4c' + ('5' * 32)

  def test_a_clean_or_unrelated_entry_is_no_drift
    assert_empty Erx::Lvgl.drift('')
    assert_empty Erx::Lvgl.drift(entry('..', 'S...', PINNED, PINNED))
    assert_empty Erx::Lvgl.drift(entry('.M', 'S.M.', PINNED, PINNED, path: 'other/sub'))
  end

  def test_a_staged_gitlink_bump_is_drift
    assert_equal ['is staged at another commit than HEAD records'],
                 Erx::Lvgl.drift(entry('M.', 'S...', PINNED, BUMPED))
  end

  def test_a_modified_checkout_names_what_differs
    assert_equal ['has changes to tracked files'], Erx::Lvgl.drift(entry('.M', 'S.M.', PINNED, PINNED))
    assert_equal ['is not at the commit the index records', 'has untracked files'],
                 Erx::Lvgl.drift(entry('.M', 'SC.U', PINNED, PINNED))
  end

  def test_an_unmerged_entry_is_a_conflict
    line = "u UU S... 160000 160000 160000 160000 #{PINNED} #{BUMPED} #{PINNED} #{Erx::Lvgl::SUBMODULE}\n"
    assert_equal ['has an unresolved merge conflict'], Erx::Lvgl.drift(line)
  end

  private

  def entry(xy, sub, head, index, path: Erx::Lvgl::SUBMODULE)
    "1 #{xy} #{sub} 160000 160000 160000 #{head} #{index} #{path}\n"
  end
end

# How erx-lvgl is built for the target (Erx::Lvgl::Program), with the commands it
# would run recorded instead of run: LVGL is compiled by the Makefile with the task
# code generation and musl's headers into a directory its flags name, and the program
# is linked by NativeRoot over that liblvgl.a, which the result names for the packer
# to attribute whole, under licenses whose notices are files of LVGL's tree. The cross
# build itself runs in the programs suite, which ships it and starts it on QEMU.
class LvglProgramTest < Minitest::Test
  # Records each command and answers git's status with an empty log: a clean checkout.
  class Runner
    attr_reader :commands

    def initialize(log)
      @log = log
      @commands = []
    end

    def run(argv, **)
      @commands << argv
      { 'log' => @log }
    end
  end

  # Generates nothing: the test reads no generated file.
  module Generated
    def self.ensure(root:) = root
  end

  # Takes NativeRoot#build_task_receipted's arguments and answers as it does.
  class Native
    attr_reader :link

    def build_task_receipted(**arguments)
      @link = arguments
      { program: 'out/erx-lvgl', receipt: 'out/erx-lvgl.receipt.json', inputs: ['out/erx-lvgl'].freeze }.freeze
    end
  end

  def test_lvgl_is_compiled_with_the_task_flags_and_the_program_linked_over_it
    Dir.mktmpdir('erx-lvgl-program') do |root|
      FileUtils.mkdir_p(File.join(root, Erx::Lvgl::SUBMODULE))
      FileUtils.touch([File.join(root, Erx::Lvgl::SUBMODULE, 'lvgl.h'), File.join(root, '.git'), log = File.join(root, 'status')])
      runner = Runner.new(log)
      native = Native.new
      built = Erx::Lvgl::Program.new(root: root, runner: runner, native: native, compiler: '/llvm/clang', archives: %w[libc.a libclang_rt.builtins.a],
                               directory: File.join(root, 'out'), jobs: 2,
                                     generated: Generated).call

      flags = Erx::Lvgl::Program.library_flags(root)
      assert_equal [*Erx::NativeRoot::CODE_FLAGS, '-isystem', File.join(root, Erx::NativeRoot::LIBC_HEADERS), '-D_BSD_SOURCE'].join(' '),
                   flags
      refute_includes flags, '-mgeneral-regs-only'
      make = runner.commands.find { |argv| argv.first == 'gmake' }
      archive = make.last
      assert_match %r{\A#{root}/build/lvgl/target/\h{16}/liblvgl\.a\z}, archive
      assert_includes make, "FLAGS=#{flags}"
      assert_includes make, 'CC=/llvm/clang'
      assert_includes make, 'AR=/llvm/llvm-ar'
      assert_includes make, 'SANITIZE='
      assert_equal [*Erx::NativeRoot::PROGRAM, *Erx::Lvgl::Program::SOURCES], native.link.fetch(:sources)
      assert_equal [archive, 'libc.a', 'libclang_rt.builtins.a'], native.link.fetch(:archives)
      refute native.link.key?(:flags)
      assert_equal archive, built.fetch(:archive)
      assert_equal ['out/erx-lvgl'], built.fetch(:inputs)
      refute_equal Erx::Lvgl::Program.library_directory(root, flags), Erx::Lvgl::Program.library_directory(root, "#{flags} -O0")
    end
  end

  # Each notice the archive's licenses need is a file of the checked-out submodule.
  def test_the_archive_notices_are_files_of_lvgl
    skip 'LVGL is not checked out' unless Erx::Lvgl.checked_out?(ErxLvglTest::ROOT)
    Erx::Lvgl::Program::NOTICES.each { |notice| assert File.file?(File.join(ErxLvglTest::ROOT, notice)), notice }
    Erx::Attribution.validate_expression(Erx::Lvgl::Program::LICENSE)
  end
end
