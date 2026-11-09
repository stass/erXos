# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/lvgl'

# erx-lvgl end to end on the host (docs/design-display.md, "The widget
# server"): the program, built from LVGL's submodule under ASan and UBSan, is run
# by the model screen test/erlang/erx_lvgl_screen.erl on stock's emulator
# (ERX_ERL and ERX_ERLC), which encodes the server's records with the
# generated erx_ui_wire and reads the program's reports and events with it.
# The model screen says what it checks.
class ErxLvglTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GENERATED = File.join(ROOT, Erx::Generated::OUTPUT)
  SOURCES = [
    File.join(GENERATED, Erx::ABI::UIWireEmitter::ERLANG_PATH),
    File.join(ROOT, 'erlang/apps/erx_display/src/erx_ui_model.erl'),
    File.join(ROOT, 'test/erlang/erx_lvgl_screen.erl')
  ].freeze

  def test_model_screen_drives_the_program
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-lvgl-test') do |work|
      run!(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, chdir: work)
      %w[x8r8g8b8 r5g6b5].each do |channel|
        output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "io:format(\"~p~n\", [erx_lvgl_screen:run(\"#{program}\", #{channel})]), halt(0)", chdir: work)
        assert_match(/events => \[\{event,3,on_click,none\}\]/, output, channel)
      end
    end
  end

  private

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
