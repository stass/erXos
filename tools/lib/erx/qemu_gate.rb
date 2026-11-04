# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bounded_file'
require_relative 'declaration_files'
require_relative 'error'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The one gate for every suite that boots the kernel under QEMU
  # (`tools/erx check-qemu`, `make check-qemu`). Each suite is one file in
  # qemu_suites/, named after the suite and found by globbing, so a new suite
  # needs no entry in a shared list; the file calls declare_suite once with a
  # callable that takes a Context and returns a Result.
  #
  # A Result is a map from a cell (a configuration such as `tcg-4cpu`, or a
  # declared case) to what happened there. The gate never turns an absence
  # into a pass:
  #   passed     ran and agreed
  #   failed     ran and disagreed, or the suite raised
  #   timed_out  was killed at its deadline
  #   partial    ran, but the guest did not finish its report or skipped
  #   not_run    could not run here, such as HVF on a host without it
  #   pending    declared before the call it tests exists; nothing ran
  # A suite is failed when any cell failed or timed out, incomplete when any
  # cell was not run or partial, pending when every cell is pending, and
  # passed otherwise. The gate passes only when no suite is failed or
  # incomplete; a pending suite is listed and does not fail it.
  module QemuGate
    CELL_STATUSES = %w[passed failed timed_out partial not_run pending].freeze
    FAILED_CELLS = %w[failed timed_out].freeze
    INCOMPLETE_CELLS = %w[partial not_run].freeze

    # What a suite sees: the repository, the accelerators asked for and those
    # this host's QEMU offers, and the build job count.
    Context = Data.define(:root, :accels, :available, :jobs) do
      # The requested accelerators this host can run, in the order asked.
      def runnable = accels & available

      # The requested accelerators this host cannot run.
      def missing = accels - available
    end

    Result = Data.define(:cells, :notes)
    Suite = Data.define(:name, :run)

    SUITE_FILES = DeclarationFiles.new('QEMU suites')
    private_constant :SUITE_FILES

    module_function

    # Each file under qemu_suites/ calls this exactly once.
    def declare_suite(run:)
      raise Error, 'QEMU suites: a suite is a callable' unless run.respond_to?(:call)

      SUITE_FILES.declare(run)
    end

    # The suites declared in directory, sorted by name. Public so the tests
    # can feed it malformed directories.
    def load_suites(directory)
      SUITE_FILES.load_all(directory).map { |name, run| Suite.new(name: name, run: run) }.freeze
    end

    def suites = (@suites ||= load_suites(File.join(__dir__, 'qemu_suites')))

    def result(cells, notes: [])
      unknown = cells.values - CELL_STATUSES
      raise Error, "QEMU suites: unknown cell status #{unknown.first.inspect}" unless unknown.empty?

      Result.new(cells: cells.freeze, notes: notes.freeze)
    end

    # The accelerators the installed QEMU lists, from `-accel help`.
    def available_accelerators(runner:, program: 'qemu-system-aarch64')
      listing = runner.run([program, '-accel', 'help'], name: 'qemu-accelerators', deadline: 30)
      QemuPlan.accelerators(BoundedFile.read(listing.fetch('log'), maximum: 64 * 1024))
    end

    # One suite's status from its cells. A suite with no cell reports
    # nothing, which is a failure, never a pass.
    def status(result)
      values = result.cells.values
      return 'failed' if values.empty? || values.any? { |value| FAILED_CELLS.include?(value) }
      return 'incomplete' if values.any? { |value| INCOMPLETE_CELLS.include?(value) }
      return 'pending' if values.all?('pending')

      'passed'
    end

    # The gate's status over the suites' statuses.
    def overall(statuses)
      return 'failed' if statuses.empty? || statuses.include?('failed')
      return 'incomplete' if statuses.include?('incomplete')

      'passed'
    end

    # Runs each suite and returns { name => Result }. A suite that raises a
    # domain error is a failed suite carrying the message; any other
    # exception is a bug in the gate and propagates.
    def run(suites:, context:)
      suites.to_h do |suite|
        [suite.name, suite.run.call(context)]
      rescue Error => error
        [suite.name, result({ 'run' => 'failed' }, notes: [error.message])]
      end
    end

    # The report as terminal lines: one row per suite, the notes of each
    # suite that did not pass, then the gate's own line.
    def table(results, context:)
      rows = results.map do |name, entry|
        cells = entry.cells.map { |cell, value| "#{cell} #{value}" }.join(', ')
        "#{name.ljust(16)} #{status(entry).ljust(11)} #{cells}"
      end
      notes = results.flat_map do |name, entry|
        status(entry) == 'passed' ? [] : entry.notes.map { |note| "#{name}: #{note}" }
      end
      statuses = results.values.map { |entry| status(entry) }
      pending = statuses.count('pending')
      [*rows, *notes,
       "qemu gate: #{overall(statuses)}; #{results.size} suites, #{pending} pending; accelerators asked: " \
       "#{context.accels.join(' ')}; available: #{context.available.join(' ')}"]
    end
  end
end
