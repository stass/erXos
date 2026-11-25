# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'platform'

module Erx
  # The board's ARM clock (docs/design-bench.md, "Other systems on the same Raspberry Pi
  # 4"): the platform record's arm_clock_hz, which every card's config.txt sets as
  # arm_freq and holds with force_turbo (BootPartition.config_txt), so erXos and every
  # system benchmarked on the board run at one known clock. A board run's record keeps
  # it in its run's details, and the side-by-side table converts a cell counted in CPU
  # cycles to nanoseconds at its own run's clock and says so (BenchSideBySide).
  module BoardClock
    # The record's key and the run detail's.
    KEY = 'arm_clock_hz'

    module_function

# The clock a platform record names, in hertz (whole megahertz, as Platform checks it
# at load), or nil when it names none.
def configured_hz(record) = record[KEY]

    # The clock the board's cards hold, from the tree at root (Netboot::PLATFORM's record;
    # the caller, which records a board run, has loaded Netboot).
    def board_hz(root) = configured_hz(Platform.load(root: root, name: Netboot::PLATFORM).record)

    # The clock a record's run held, in hertz, or nil when the run recorded none.
    def recorded_hz(run)
      hz = run.details[KEY]
      hz.is_a?(Integer) && hz.positive? ? hz : nil
    end
  end
end
