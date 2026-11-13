# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_screen_core_tests.erl, the exhaustive cases of the screen's pure
# core, against erx_screen_core compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies). Then each seeded fault of docs/design-display.md's
# "Who touches pixels" item, applied to a copy of the module, must fail the case named for
# it, which shows that case runs the code the fault breaks. The seeded runs are
# independent, so they run at once.
class ErxScreenCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding the module (compiled whole, ErlangBuild), the module and the suite.
  APPLICATIONS = %w[erx_display].freeze
  MODULE = 'erlang/apps/erx_display/src/erx_screen_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_screen_core_tests.erl].freeze
  DEADLINE_SECONDS = '600'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'an off-by-one in the visible region: each run of a band ends a pixel early',
             anchor: '[{X, Next, topmost(Now, Background)} | sweep(',
             replacement: '[{X, Next - 1, topmost(Now, Background)} | sweep(',
             catching_case: 'tiles_cover_every_pixel_once_test_'),
    Seed.new(fault: 'an off-by-one in the visible region: a layer misses the first band it crosses',
             anchor: 'LY0 =< Y0, LY1 >= Y1].',
             replacement: 'LY0 < Y0, LY1 >= Y1].',
             catching_case: 'tiles_cover_every_pixel_once_test_'),
    Seed.new(fault: "a window's decorations stacked first under last",
             anchor: '|| {R, Color} <- lists:reverse(Decorations)]',
             replacement: '|| {R, Color} <- Decorations]',
             catching_case: 'tiles_cover_every_pixel_once_test_'),
    Seed.new(fault: 'a composing layout after direct mode that trusts the stale screen image',
             anchor: '{{direct, _}, compose} -> unknown;',
             replacement: '{{direct, _}, compose} -> Bands;',
             catching_case: 'layout_changes_expose_and_fill_exactly_what_changed_test_'),
    Seed.new(fault: 'a moved window taken to show what it showed',
             anchor: 'content({window, _, _, _} = Source) -> Source;',
             replacement: 'content({window, Id, Proc, _}) -> {window, Id, Proc};',
             catching_case: 'layout_changes_expose_and_fill_exactly_what_changed_test_'),
    Seed.new(fault: 'a window id shown again by another process taken to show what the old one did',
             anchor: 'content({window, _, _, _} = Source) -> Source;',
             replacement: 'content({window, Id, _, Origin}) -> {window, Id, Origin};',
             catching_case: 'a_window_id_shown_again_by_another_process_is_exposed_whole_test'),
    Seed.new(fault: 'a decoration refilled over the background of its own colour',
             anchor: 'content({decoration, _, Color}) -> {fill, Color};',
             replacement: 'content({decoration, Id, Color}) -> {decoration, Id, Color};',
             catching_case: 'layout_changes_expose_and_fill_exactly_what_changed_test_'),
    Seed.new(fault: 'a comparison that drops the rest of the taller band',
             anchor: 'rest_band(Y1, BandY1, Runs, Rest) -> [{Y1, BandY1, Runs} | Rest].',
             replacement: 'rest_band(_, _, _, Rest) -> Rest.',
             catching_case: 'layout_changes_expose_and_fill_exactly_what_changed_test_'),
    Seed.new(fault: 'a plan that pushes no fill',
             anchor: 'push => [R || {R, _} <- Fills]},',
             replacement: 'push => []},',
             catching_case: 'layout_changes_expose_and_fill_exactly_what_changed_test_'),
    Seed.new(fault: "a flush not clipped to the window's image",
             anchor: 'true -> flush_plan(Id, Proc, [intersect(R, Bounds) || R <- Rects], Screen);',
             replacement: 'true -> flush_plan(Id, Proc, Rects, Screen);',
             catching_case: 'flush_copies_exactly_the_visible_dirty_area_test_'),
    Seed.new(fault: "a flush not clipped to the window's visible region",
             anchor: '{pushed_from(Id, Mode), [Piece || Part <- Region,',
             replacement: '{pushed_from(Id, Mode), [Piece || Part <- [{-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff}],',
             catching_case: 'flush_copies_exactly_the_visible_dirty_area_test_'),
    Seed.new(fault: "a flush by another process taken for the window's",
             anchor: '#{Id := {Proc, Region}} ->',
             replacement: '#{Id := {_, Region}} ->',
             catching_case: 'a_flush_by_another_process_of_the_same_id_copies_nothing_test'),
    Seed.new(fault: 'a comparison that joins changed runs across an unchanged one',
             anchor: 'merge_runs([{X0, X, Source}, {X, X1, Source} | Rest]) ->',
             replacement: 'merge_runs([{X0, _, Source}, {_, X1, Source} | Rest]) ->',
             catching_case: 'layout_changes_on_a_strip_expose_and_fill_exactly_what_changed_test_'),
    Seed.new(fault: 'direct mode for a decorated window',
             anchor: 'mode_of(Screen, [#{id := Id, rect := Screen, decorations := []}]) -> {direct, Id};',
             replacement: 'mode_of(Screen, [#{id := Id, rect := Screen}]) -> {direct, Id};',
             catching_case: 'direct_mode_is_one_undecorated_window_covering_the_screen_test'),
    Seed.new(fault: 'a dirty list that holds a seventeenth rectangle',
             anchor: 'false when length(Dirty) < ?DIRTY_MAX -> [Rect | Dirty];',
             replacement: 'false when length(Dirty) =< ?DIRTY_MAX -> [Rect | Dirty];',
             catching_case: 'seventeenth_dirty_rectangle_yields_its_bounding_box_test'),
    Seed.new(fault: 'a flush of more than sixteen rectangles',
             anchor: 'length(Rects) =< ?DIRTY_MAX of',
             replacement: 'true of',
             catching_case: 'more_than_sixteen_dirty_rectangles_are_refused_test'),
    Seed.new(fault: 'a layout that shows one window twice',
             anchor: 'length(lists:usort(Ids)) =:= length(Ids)',
             replacement: 'true',
             catching_case: 'malformed_input_is_refused_test'),
    Seed.new(fault: "a coordinate past draw(3)'s 32 bits",
             anchor: 'is_integer(C) andalso C >= ?COORD_MIN andalso C =< ?COORD_MAX.',
             replacement: 'is_integer(C).',
             catching_case: 'malformed_input_is_refused_test'),
    Seed.new(fault: 'an improper list that crashes the check',
             anchor: 'every(_, _) -> false.',
             replacement: 'every(_, Tail) -> error({improper, Tail}).',
             catching_case: 'improper_lists_are_refused_test')
  ].freeze

  def test_core_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "anchor for #{seed.fault} is not once in #{MODULE_SOURCE}"
    end
    runs = SEEDS.map do |seed|
      Thread.new { [seed, *eunit(source.sub(seed.anchor, seed.replacement))] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_match(failed_case(seed.catching_case), output, "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  # EUnit names a plain case by its function and a generator's case by the fun inside it.
  def failed_case(name) = %r{#{Regexp.escape(name)}(/0-fun-\d+-)?\.\.\.(\[[^\]]*\] )?\*failed\*}

  def eunit(module_text)
    Dir.mktmpdir('erx-screen-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_screen_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
