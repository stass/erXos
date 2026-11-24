# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/share_windows'

# The reader of MODE_SHARE's windows and their summary (docs/design-bench.md,
# "2. `sched`: how a CPU is shared").
class ShareWindowsTest < Minitest::Test
  HZ = 24_000_000
  RUN = "share: run hz #{HZ} spinners 2 cpu 3 windows 2 window_ms 1000".freeze

  def window(window, spinner, iterations:, longest: 24_000)
    "share: window #{window} spinner #{spinner} iterations #{iterations} longest #{longest} lost 3 loop 1"
  end

  def serial(lines) = ['erx: task: cpus 4', *lines, 'erx: task: share ok'].join("\r\n")

  def test_a_run_gives_each_window_its_shares_ratio_and_gaps
    run = Erx::ShareWindows.read(serial([RUN, window(0, 0, iterations: 300), window(0, 1, iterations: 100),
                                         window(1, 0, iterations: 200), window(1, 1, iterations: 200, longest: 48_000)]))
    first, second = run.summaries
    assert_equal [0.75, 0.25], first.shares
    assert_in_delta 1.0 / 3, first.ratio
    assert_equal [1000, 1000], first.longest_us
    assert_equal [3, 3], first.lost
    assert_equal [1000, 2000], second.longest_us
    assert_in_delta 1.0, second.ratio
    assert_equal 3, run.cpu
  end

  # A spinner that never published leaves the run short; one line out of its place is
  # another spinner's, which must not be read as this one's.
  def test_a_short_or_misordered_run_is_refused
    whole = [window(0, 0, iterations: 1), window(0, 1, iterations: 1), window(1, 0, iterations: 1), window(1, 1, iterations: 1)]
    assert_raises(Erx::Error) { Erx::ShareWindows.read(serial([RUN, *whole.take(3)])) }
    assert_raises(Erx::Error) { Erx::ShareWindows.read(serial([RUN, whole[1], whole[0], *whole.drop(2)])) }
    assert_raises(Erx::Error) { Erx::ShareWindows.read(serial([RUN, RUN, *whole.take(3)])) }
    assert_raises(Erx::Error) { Erx::ShareWindows.read(serial(whole)) }
  end

  # A spinner starved until the others were done still publishes its windows, with no pass in
  # them, and one that started after the warm-up timed no loop: the share case refuses both.
  def test_the_share_case_refuses_a_spinner_that_never_ran
    ran = [RUN, window(0, 0, iterations: 9), window(0, 1, iterations: 9), window(1, 0, iterations: 9), window(1, 1, iterations: 9)]
    Erx::ShareWindows.judge(serial(ran))
    starved = ran.dup.tap { |lines| lines[4] = window(1, 1, iterations: 0, longest: HZ) }
    assert_raises(Erx::Error) { Erx::ShareWindows.judge(serial(starved)) }
    untimed = ran.dup.tap { |lines| lines[2] = lines[2].sub(/loop 1\z/, "loop #{Erx::ShareWindows::NO_LOOP}") }
    assert_raises(Erx::Error) { Erx::ShareWindows.judge(serial(untimed)) }
  end
end
