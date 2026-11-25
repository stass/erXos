# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/glyphs'
require_relative '../../tools/lib/erx/lvgl'
require_relative '../../tools/lib/erx/origin'
require_relative '../../tools/lib/erx/ppm'
require_relative '../../tools/lib/erx/screen_reference'

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

  # The display suite's lvgl cell compares the guest's screen with a reference picture
  # (tools/lib/erx/display_domain.rb, LVGL): this checks that the reference is what the
  # host's erx-lvgl draws of the cell client's tree (erx_kiosk_test:tree/0) on the
  # suite's screen, the reference's own size, so the guest's picture equals the host's
  # render. ERX_RECORD_REFERENCE=1 writes the reference from the render instead, for a
  # person who has looked at the picture. The client is drawn in the dark palette, which
  # the development manifest's display entry chooses and the display_domain suite boots.
  KIOSK_REFERENCE = 'display-lvgl'
  KIOSK_CLIENT = %w[test/erlang/apps/erx_kiosk_test/src/erx_kiosk_test.erl].freeze
  def test_the_kiosk_reference_is_the_programs_picture
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    references = File.join(ROOT, 'test/display/reference')
    Dir.mktmpdir('erx-lvgl-kiosk') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS + KIOSK_CLIENT)
      reference = Erx::ScreenReference.load(references, KIOSK_REFERENCE)
      width = reference.width
      height = reference.height
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program, palette: 'dark')}, " \
           "erx_kiosk_test:tree(), {#{width}, #{height}})), halt(0)",
           chdir: work)
      image = Erx::Ppm::Image.new(width: width, height: height, pixels: File.binread(File.join(work, 'picture.rgb')))
      if ENV['ERX_RECORD_REFERENCE'] == '1'
        digest, picture = Erx::ScreenReference.encode(image)
        File.write(File.join(references, "#{KIOSK_REFERENCE}.sha256"), digest)
        File.binwrite(File.join(references, "#{KIOSK_REFERENCE}.ppm.gz"), picture)
      end
      assert_nil Erx::ScreenReference.check(image, directory: references, name: KIOSK_REFERENCE)
    end
  end

  # The palette the program is started with colours the picture
  # (abi/theme.txt): the kiosk client drawn in the dark palette is another
  # picture than in the light one, which the program takes when started
  # with none, and a palette the theme does not name ends the program.
  def test_the_palette_argument_colours_the_picture
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-lvgl-palette') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS + KIOSK_CLIENT)
      light, named_light, dark = [[], ['light'], ['dark']].map do |args|
        screen = screen(program).sub(/\}\z/, ", args => #{args.inspect}}")
        run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
             "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen}, " \
             'erx_kiosk_test:tree(), {320, 200})), halt(0)', chdir: work)
        File.binread(File.join(work, 'picture.rgb'))
      end
      assert_equal light, named_light, 'light is the default'
      # The window's ground, the top left pixel, is each palette's window colour.
      assert_equal [0xf6, 0xf5, 0xf2], light.unpack('C3'), 'the light window colour'
      assert_equal [0x0d, 0x0f, 0x2a], dark.unpack('C3'), 'the dark window colour'
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', RbConfig.ruby, LAUNCHER,
                                       File.join(work, 'picture.rgb'), program, 'sepia', stdin_data: '')
      refute status.success?
      assert_match(/no palette is named sepia/, output)
    end
  end

  # A label's trend colours its text (abi/formats/ui.txt, ui_trend): up in the
  # palette's ok, down in its critical, each over the role's own colour, and
  # flat in the role's; a label drawn up holds the ok colour and none of the
  # critical one.
  def test_a_label_s_trend_colours_its_text
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    ok = [0x2f, 0x7d, 0x4f].pack('C3')
    critical = [0xb3, 0x36, 0x2c].pack('C3')
    Dir.mktmpdir('erx-lvgl-trend') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      up, down, flat = %w[up down flat].map do |trend|
        tree = "{column, \#{}, [{label, \#{text => <<\"MMMM 88.8%\">>, role => title, trend => #{trend}}, []}]}"
        run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
             "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program)}, #{tree}, {200, 60})), " \
             'halt(0)', chdir: work)
        File.binread(File.join(work, 'picture.rgb')).scan(/.../mn)
      end
      assert_includes up, ok
      refute_includes up, critical
      assert_includes down, critical
      refute_includes down, ok
      refute_includes flat, ok
      refute_includes flat, critical
    end
  end

  # A role's text is drawn in the theme's font for that role, at its size and
  # weight (abi/theme.txt), not in a face of another size: the ink of a run
  # of H, where a pixel nearer the text's colour than the background's is
  # ink, spans the pen's whole-pixel advances of Inter's H at the role's size
  # and the columns of one H whose coverage is at least half, as erx-raster
  # gives them. heading, 15 pixels, is a size no LVGL built-in face has.
  def test_a_role_s_text_is_drawn_in_its_theme_font
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    theme = Erx::ABI::Theme.read(root: ROOT)
    role = theme.roles.fetch('heading')
    letters = 6
    h = Erx::Raster.locate(root: ROOT)
                   .rasterise(font: File.join(ROOT, Erx::Glyphs.font_file(theme, role)), size: role.size,
                              glyphs: ['U+0048'], runner: runner).glyphs.first
    inked = h.rows.flat_map { |row| row.bytes.each_index.select { |column| row.getbyte(column) >= 128 } }
    expected = ((letters - 1) * ((h.advance + 32) >> 6)) + inked.max - inked.min + 1
    Dir.mktmpdir('erx-lvgl-face') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      tree = "{column, \#{}, [{label, \#{text => <<\"#{'H' * letters}\">>, role => heading}, []}]}"
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program)}, #{tree}, {200, 60})), " \
           'halt(0)', chdir: work)
      assert_equal expected, ink_span(File.binread(File.join(work, 'picture.rgb')).bytes.each_slice(3).each_slice(200).to_a)
    end
  end

  private

  # The columns from the first to the last that hold ink in ROWS of [r, g, b]
  # pixels: a pixel farther from the background, the commonest colour, than
  # half the distance of the farthest pixel.
  def ink_span(rows)
    background = rows.flatten(1).tally.max_by { |_, count| count }.first
    distance = ->(pixel) { pixel.zip(background).sum { |a, b| (a - b).abs } }
    far = rows.flatten(1).map(&distance).max
    columns = rows.flat_map { |row| row.each_index.select { |column| 2 * distance.call(row[column]) > far } }
    columns.max - columns.min + 1
  end

  # The model screen's map of the program and how to start it, as an Erlang term: in
  # palette, a name of abi/theme.txt's, or erx-lvgl's default, light, with none.
  def screen(program, palette: nil)
    pairs = { program: program, ruby: RbConfig.ruby, launcher: LAUNCHER }.map { |key, path| "#{key} => #{path.inspect}" }
    pairs << "args => [#{palette.inspect}]" if palette
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
      assert_equal 'LVGL is not checked out at display/lvgl/lvgl; run `tools/erx setup`', error.message
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

  # Records each git command and answers with the log it was given.
  class RecordingRunner
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

  # When git's configuration names a local path as the submodule's URL, git
  # refuses the clone unless the file transport is allowed: the clone allows
  # it for its own command and the status check does not.
  def test_init_allows_the_file_transport_for_the_clone_alone
    Dir.mktmpdir('erx-lvgl-submodule') do |root|
      FileUtils.touch([File.join(root, '.git'), log = File.join(root, 'status')])
      runner = RecordingRunner.new(log)
      Erx::Lvgl.init(root: root, runner: runner)
      Erx::Lvgl.send(:status, root: root, runner: runner)
      assert_equal 2, runner.commands.size
      clone, status = runner.commands
      assert_equal ['git', '-c', 'core.fsmonitor=false', '-c', 'protocol.file.allow=always', '-C', root,
                    'submodule', 'update', '--init', '--depth', '1', '--', Erx::Lvgl::SUBMODULE], clone
      assert_empty status.grep(/protocol\.file/)
    end
  end

  # A fresh worktree clones LVGL from the copy its main checkout keeps, with that
  # path as the URL for the one command and no network.
  def test_init_local_clones_from_the_main_checkouts_copy_for_the_one_command
    Dir.mktmpdir('erx-lvgl-submodule') do |main|
      store = File.join(main, '.git/modules', Erx::Lvgl::SUBMODULE)
      FileUtils.mkdir_p(store)
      worktree = File.join(main, 'wt')
      FileUtils.mkdir_p([File.join(main, '.git/worktrees/wt'), worktree])
      File.write(File.join(main, '.git/worktrees/wt/commondir'), "../..\n")
      File.write(File.join(worktree, '.git'), "gitdir: #{File.join(main, '.git/worktrees/wt')}\n")
      FileUtils.mkdir_p(File.join(worktree, Erx::Lvgl::SUBMODULE))
      FileUtils.touch(log = File.join(worktree, Erx::Lvgl::SUBMODULE, '.git'))
      runner = RecordingRunner.new(log)
      assert_equal "LVGL: cloned display/lvgl/lvgl from #{store}", Erx::Lvgl.init_local(root: worktree, runner: runner)
      assert_equal ['git', '-c', 'core.fsmonitor=false', '-c', 'protocol.file.allow=always',
                    '-c', "submodule.display/lvgl/lvgl.url=#{store}", '-C', worktree,
                    'submodule', 'update', '--init', '--depth', '1', '--', Erx::Lvgl::SUBMODULE], runner.commands.first
      assert_equal ['git', '-c', 'core.fsmonitor=false', '-C', File.join(worktree, Erx::Lvgl::SUBMODULE),
                    'remote', 'set-url', 'origin', 'https://github.com/stass/lvgl'], runner.commands.last
      assert_equal 2, runner.commands.size
    end
  end

  def test_init_local_without_a_copy_refuses_and_names_the_fetch
    Dir.mktmpdir('erx-lvgl-submodule') do |root|
      FileUtils.mkdir_p(File.join(root, '.git'))
      error = assert_raises(Erx::Error) { Erx::Lvgl.init_local(root: root, runner: nil) }
      assert_match(/no local copy of display\/lvgl\/lvgl .* git submodule update --init display\/lvgl\/lvgl/, error.message)
    end
  end

  # The real thing: a superproject with the submodule, a worktree of it, and the clone
  # made from the main checkout's copy while the URL .gitmodules names is unreachable.
  def test_init_local_checks_out_the_gitlink_commit_in_a_real_worktree
    Dir.mktmpdir('erx-lvgl-submodule') do |directory|
      git = lambda do |*arguments, chdir:|
        system({ 'GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_SYSTEM' => '/dev/null' },
               'git', '-c', 'protocol.file.allow=always', '-c', 'user.name=t', '-c', 'user.email=t@example.com',
               '-c', 'init.defaultBranch=main', *arguments, chdir: chdir, out: File::NULL, err: File::NULL) || flunk("git #{arguments.first} failed")
      end
      upstream = File.join(directory, 'upstream')
      FileUtils.mkdir_p(upstream)
      git.call('init', chdir: upstream)
      File.write(File.join(upstream, 'lvgl.h'), "pinned\n")
      git.call('add', 'lvgl.h', chdir: upstream)
      git.call('commit', '-m', 'pinned', chdir: upstream)
      main = File.join(directory, 'main')
      FileUtils.mkdir_p(main)
      git.call('init', chdir: main)
      git.call('submodule', 'add', upstream, Erx::Lvgl::SUBMODULE, chdir: main)
      git.call('commit', '-m', 'super', chdir: main)
      FileUtils.rm_rf(upstream)
      worktree = File.join(directory, 'wt')
      git.call('worktree', 'add', '-b', 'topic', worktree, chdir: main)
      refute Erx::Lvgl.checked_out?(worktree)
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      Erx::Lvgl.init_local(root: worktree, runner: runner)
      assert_equal "pinned\n", File.read(File.join(worktree, Erx::Lvgl::SUBMODULE, 'lvgl.h'))
      origin = IO.popen(['git', '-C', File.join(worktree, Erx::Lvgl::SUBMODULE), 'config', 'remote.origin.url'], &:read).strip
      assert_equal 'https://github.com/stass/lvgl', origin
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

  # Writes no glyphs: the test compiles no font.
  module Glyphs
    def self.ensure(root:, runner:) = root
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
      headers = File.join(root, Erx::NativeRoot::LIBC_SYSROOT, 'include-0123456789abcdef')
      stale = File.join(root, Erx::Lvgl::Program::LIBRARY, '0000000000000000')
      FileUtils.mkdir_p([headers, stale])
      runner = Runner.new(log)
      native = Native.new
      built = Erx::Lvgl::Program.new(root: root, runner: runner, native: native, compiler: '/llvm/clang', archives: %w[libc.a libclang_rt.builtins.a],
                               directory: File.join(root, 'out'), jobs: 2,
                                     generated: Generated, glyphs: Glyphs).call

      flags = Erx::Lvgl::Program.library_flags(root)
      assert_equal [*Erx::NativeRoot::CODE_FLAGS, '-isystem', headers, '-D_BSD_SOURCE'].join(' '),
                   flags
      refute_includes flags, '-mgeneral-regs-only'
      make = runner.commands.find { |argv| argv.first == 'gmake' }
      archive = make.last
      assert_match %r{\A#{root}/build/lvgl/target/\h{16}/liblvgl\.a\z}, archive
      refute File.exist?(stale), "an earlier flags' directory is removed"
      assert_includes make, "FLAGS=#{flags}"
      assert_includes make, 'CC=/llvm/clang'
      assert_includes make, 'AR=/llvm/llvm-ar'
      assert_includes make, 'SANITIZE='
      assert_includes make, "GLYPHS=#{root}/build/glyphs"
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
