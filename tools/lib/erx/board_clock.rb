# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The board's ARM clock (docs/design-bench.md, "The board's ARM clock"): the platform
  # record's arm_clock_hz, which every card's config.txt sets as arm_freq and holds with
  # force_turbo (BootPartition.config_txt), so erXos and every system benchmarked on the
  # board run at one configured clock, short of the firmware's throttling. A bench set's
  # build record states the clock its config.txt sets (BootPartition.card_settings); a board
  # run's record copies it from the sets it booted into its run's details, and the
  # side-by-side table converts a cell counted in CPU cycles to nanoseconds at its own
  # run's clock and says so (BenchSideBySide). A set laid out without the clock, or a log
  # without its set's record, gives a run with none, whose cycles stay cycles.
  module BoardClock
    # The key of the platform record, of a set's build record and of a run's details.
    KEY = 'arm_clock_hz'

    module_function

    # The clock map states, in hertz: a platform record, a set's build record or a run's
    # details, which label names; nil when it states none. A clock that is not a positive
    # whole number of megahertz, the unit config.txt's arm_freq takes, is refused, so a
    # corrupt record never reads as one without a clock.
    def stated_hz(map, label:)
      hz = map[KEY]
      return nil if hz.nil?
      raise Error, "#{label}: #{KEY} is not a positive whole number of megahertz" unless
        hz.is_a?(Integer) && hz.positive? && (hz % 1_000_000).zero?

      hz
    end
  end
end
