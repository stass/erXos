# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # What a Raspberry Pi card's config.txt sets that a board run's record keeps
  # (docs/design-bench.md, "The board's ARM clock"). The ARM clock is the platform
  # record's arm_clock_hz, which every bench set's config.txt sets as arm_freq and holds
  # with force_turbo, so erXos and every system benchmarked on the board run at one
  # configured clock, short of the firmware's throttling; a card that is no bench set
  # keeps the firmware's dynamic clocking. total_mem is the memory the firmware reports,
  # of which gpu_mem goes to the VideoCore. BootPartition.write_set writes a set's
  # config.txt and its build record from one Card (BootPartition.card_settings); a board
  # run's record keeps the clock in its run's details and the memory in its environment,
  # and the side-by-side table converts a cell counted in CPU cycles to nanoseconds at its
  # own run's clock and says so (BenchSideBySide).
  module CardSettings
    # The key of the clock in the platform record, a set's build record and a run's details.
    CLOCK_KEY = 'arm_clock_hz'
    # The key of total_mem in a set's build record.
    MEMORY_KEY = 'total_mem_mib'

    # The settings: the ARM clock in hertz and total_mem in MiB, each nil when unknown.
    Card = Data.define(:arm_clock_hz, :memory_mib) do
      # The settings as a set's build record states them.
      def to_record = { CLOCK_KEY => arm_clock_hz, MEMORY_KEY => memory_mib }.compact
    end

    module_function

    # The clock map states, in hertz: a platform record, a set's build record or a run's
    # details, which label names; nil when it states none. A clock that is not a positive
    # whole number of megahertz, the unit config.txt's arm_freq takes, is refused, so a
    # corrupt record never reads as one without a clock.
    def clock_hz(map, label:)
      hz = map[CLOCK_KEY]
      return nil if hz.nil?
      raise Error, "#{label}: #{CLOCK_KEY} is not a positive whole number of megahertz" unless
        hz.is_a?(Integer) && hz.positive? && (hz % 1_000_000).zero?

      hz
    end

    # The settings a set's build record states (Card); a record that is not a JSON object,
    # or a value that is not a setting, is refused. label names the record.
    def read(record, label:)
      raise Error, "#{label} is not a JSON object" unless record.is_a?(Hash)

      memory = record[MEMORY_KEY]
      raise Error, "#{label}: #{MEMORY_KEY} is not a positive whole number" unless
        memory.nil? || (memory.is_a?(Integer) && memory.positive?)

      Card.new(arm_clock_hz: clock_hz(record, label: label), memory_mib: memory)
    end
  end
end
