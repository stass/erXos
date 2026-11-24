# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The windows test/guest/native_task/program.c's MODE_SHARE writes (docs/design-bench.md,
  # "2. `sched`: how a CPU is shared"): one run line, then one line per window and spinner,
  # window by window and spinner by spinner. The lines are a guest's, so the reader takes
  # only that shape and raises on anything else: a second run line, a line out of order,
  # a window or spinner past the run's, or a run that stops short.
  #
  #   share: run hz H spinners N cpu C windows W window_ms M
  #   share: window K spinner S iterations I longest G lost L loop P
  #
  # G and P are counter ticks: G a window's longest gap between two reads, P the spinner's
  # loop period, its shortest gap of a tick or more in the warm-up, or NO_LOOP; L the gaps
  # over twenty loop periods, the turns it lost. P is at least a tick, so where a pass of the
  # loop takes less than a tick, L counts the interrupts within a turn as well as lost turns.
  module ShareWindows
    RUN_LINE = /\Ashare: run hz (?<hz>[1-9][0-9]{0,11}) spinners (?<spinners>[1-8]) cpu (?<cpu>[0-9]{1,2}) windows (?<windows>[1-9][0-9]?) window_ms (?<window_ms>[1-9][0-9]{0,4})\z/n
    WINDOW_LINE = /\Ashare: window (?<window>[0-9]{1,2}) spinner (?<spinner>[0-7]) iterations (?<iterations>[0-9]{1,20}) longest (?<longest>[0-9]{1,20}) lost (?<lost>[0-9]{1,20}) loop (?<loop>[0-9]{1,20})\z/n
    SHARE_LINE = /\Ashare: /n
    MICROS = 1_000_000
    # The loop period of a spinner whose warm-up gave it no gap of a tick or more.
    NO_LOOP = (1 << 64) - 1

    # One spinner's window: its passes, its longest gap and its lost turns.
    Spinner = Data.define(:iterations, :longest, :lost, :loop)
    # One window: each spinner's share of the passes, the smallest share over the largest,
    # each spinner's longest gap in microseconds and its lost turns.
    Summary = Data.define(:shares, :ratio, :longest_us, :lost)
    # by_window holds, for each window, its Spinner by spinner.
    Run = Data.define(:hz, :cpu, :window_ms, :by_window) do
      # By window, a Summary of its spinners.
      def summaries
        by_window.map do |spinners|
          total = spinners.sum(&:iterations)
          shares = spinners.map { |spinner| total.zero? ? 0.0 : spinner.iterations.fdiv(total) }
          Summary.new(shares: shares, ratio: shares.max.zero? ? 0.0 : shares.min / shares.max,
                      longest_us: spinners.map { |spinner| spinner.longest * MICROS / hz }, lost: spinners.map(&:lost))
        end
      end
    end

    module_function

    # The run in serial's share lines.
    def read(serial)
      head, *rest = serial.b.split(/\r?\n/n).grep(SHARE_LINE)
      run = RUN_LINE.match(head.to_s) or raise Error, "the share run begins with #{head.inspect}, not its run line"
      spinners, windows = run[:spinners].to_i, run[:windows].to_i
      expected = (0...windows).to_a.product((0...spinners).to_a)
      raise Error, "the share run has #{rest.size} window lines, not #{expected.size}" unless rest.size == expected.size

      kept = rest.zip(expected).map { |line, (window, spinner)| spinner_of(line, window: window, spinner: spinner) }
      Run.new(hz: run[:hz].to_i, cpu: run[:cpu].to_i, window_ms: run[:window_ms].to_i,
              by_window: kept.each_slice(spinners).to_a)
    end

    # The run in serial, held to the sched benchmark's correct result: every spinner reports
    # each window, having run in it and timed its loop in the warm-up. How long its gaps are is
    # the benchmark's measurement, not a verdict.
    def judge(serial)
      run = read(serial)
      run.by_window.each_with_index do |spinners, window|
        idle = spinners.each_index.select { |spinner| spinners[spinner].iterations.zero? }
        raise Error, "share: window #{window}: spinners #{idle.join(', ')} never ran" unless idle.empty?
      end
      untimed = run.by_window.first.each_index.select { |spinner| run.by_window.first[spinner].loop == NO_LOOP }
      raise Error, "share: spinners #{untimed.join(', ')} timed no loop in the warm-up" unless untimed.empty?

      run
    end

    def spinner_of(line, window:, spinner:)
      match = WINDOW_LINE.match(line)
      unless match && match[:window].to_i == window && match[:spinner].to_i == spinner
        raise Error, "the share run's line for window #{window}, spinner #{spinner} is #{line.inspect}"
      end

      Spinner.new(iterations: match[:iterations].to_i, longest: match[:longest].to_i, lost: match[:lost].to_i,
                  loop: match[:loop].to_i)
    end
    private_class_method :spinner_of
  end
end
