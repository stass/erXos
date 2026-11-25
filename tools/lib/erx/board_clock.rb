# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The board's ARM clock (docs/design-bench.md, "The board's ARM clock"): the platform
  # record's arm_clock_hz, which every card's config.txt sets as arm_freq and holds with
  # force_turbo (BootPartition.config_txt), so erXos and every system benchmarked on the
  # board run at one configured clock, short of the firmware's throttling. A bench set's
  # build record states the clock its config.txt sets (BootPartition.lay_out_set); a board
  # run's record copies it from the sets it booted into its run's details, and the
  # side-by-side table converts a cell counted in CPU cycles to nanoseconds at its own
  # run's clock and says so (BenchSideBySide). A set laid out without the clock, or a log
  # without its set's record, gives a run with none, whose cycles stay cycles.
  module BoardClock
    # The key of the platform record, of a set's build record and of a run's details.
    KEY = 'arm_clock_hz'

    module_function

    # The clock a platform record names, in hertz (whole megahertz, as Platform checks it
    # at load), or nil when it names none.
    def configured_hz(record) = record[KEY]

    # The clock a set's build record or a run's details state, or nil when they state none.
    def stated_hz(map)
      hz = map[KEY]
      hz.is_a?(Integer) && hz.positive? ? hz : nil
    end
  end
end
