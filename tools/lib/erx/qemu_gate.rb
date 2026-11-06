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
  # needs no entry in a shared list; the file calls declare_suite once with
  # the cells it expects and a callable that takes a Context and returns a
  # Result.
  #
  # A Result is a map from a cell (a configuration such as `hvf-4cpu`, or a
  # declared case) to what happened there. The gate never turns an absence
  # into a pass:
  #   passed     ran and agreed
  #   failed     ran and disagreed, or the suite raised
  #   timed_out  was killed at its deadline
  #   partial    ran, but the guest did not finish its report or skipped
  #   not_run    could not run, or an expected cell the suite did not report
  #   pending    declared before the call it tests exists; nothing ran
  # A suite is failed when any cell failed or timed out, incomplete when any
  # cell was not run or partial, pending when every cell is pending, and
  # passed otherwise. The gate passes only when no suite is failed or
  # incomplete; a pending suite is listed and does not fail it.
  module QemuGate
    # Every suite runs under this accelerator.
    SUITE_ACCELERATOR = 'hvf'
    # TCG runs only the deterministic-mode transcript (`erx.det=1` needs TCG
    # with instruction counting) and one boot smoke of the production image
    # at one CPU; the production_image suite owns both, as cells of its own.
    SMOKE_ACCELERATOR = 'tcg'
    # What the host's QEMU must offer for the gate to run at all; check_qemu
    # refuses a host without either before anything is built, so no suite
    # asks which accelerators it has.
    REQUIRED_ACCELERATORS = [SUITE_ACCELERATOR, SMOKE_ACCELERATOR].freeze

    CELL_STATUSES = %w[passed failed timed_out partial not_run pending].freeze
    FAILED_CELLS = %w[failed timed_out].freeze
    INCOMPLETE_CELLS = %w[partial not_run].freeze

    # What a suite sees: the repository and the build job count.
    Context = Data.define(:root, :jobs)

    # Cells map a name to one of CELL_STATUSES; a status outside it cannot be built.
    Result = Data.define(:cells, :notes) do
      def initialize(cells:, notes:)
        unknown = cells.values - CELL_STATUSES
        raise Error, "QEMU suites: unknown cell status #{unknown.first.inspect}" unless unknown.empty?

        super(cells: cells.dup.freeze, notes: notes.dup.freeze)
      end
    end

    # A suite's cells are the ones it must report. The gate holds it to them
    # (QemuGate.run), so a run that leaves one out cannot pass.
    Suite = Data.define(:name, :cells, :run) do
      def initialize(name:, cells:, run:)
        valid = cells.is_a?(Array) && !cells.empty? && cells.all?(String) && cells.uniq.size == cells.size
        raise Error, "QEMU suites: #{name} declares no list of distinct cells" unless valid
        raise Error, "QEMU suites: #{name} is not a callable" unless run.respond_to?(:call)

        super(name: name, cells: cells.dup.freeze, run: run)
      end
    end

    SUITE_FILES = DeclarationFiles.new('QEMU suites')
    private_constant :SUITE_FILES

    module_function

    # Each file under qemu_suites/ calls this exactly once, with the cells
    # its run reports; load_suites checks both as it builds each Suite.
    def declare_suite(cells:, run:)
      SUITE_FILES.declare([cells, run])
    end

    # The suites declared in directory, sorted by name. Public so the tests
    # can feed it malformed directories.
    def load_suites(directory)
      SUITE_FILES.load_all(directory).map { |name, (cells, run)| Suite.new(name: name, cells: cells, run: run) }.freeze
    end

    def suites = (@suites ||= load_suites(File.join(__dir__, 'qemu_suites')))

    def result(cells, notes: [])
      Result.new(cells: cells, notes: notes)
    end

    # The cells of a suite that runs under SUITE_ACCELERATOR at each count of cpus.
    def suite_cells(cpus) = cpus.map { |count| "#{SUITE_ACCELERATOR}-#{count}cpu" }

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
    # Passes only when some suite ran and passed: a gate whose suites are all
    # pending ran nothing, and says so as incomplete.
    def overall(statuses)
      return 'failed' if statuses.empty? || statuses.include?('failed')
      return 'incomplete' if statuses.include?('incomplete') || !statuses.include?('passed')

      'passed'
    end

    # Runs each suite and returns { name => Result }. Each expected cell the
    # suite did not report is not_run, with a note naming it, so a suite that
    # silently skips part of its run is incomplete and never passes. A cell
    # beyond the expected ones, such as a conformance case, is kept as
    # reported. A suite that raises a domain error is a failed suite carrying
    # the message; any other exception is a bug in the gate and propagates.
    def run(suites:, context:)
      suites.to_h do |suite|
        [suite.name, held_to_its_cells(suite, suite.run.call(context))]
      rescue Error => error
        [suite.name, result({ 'run' => 'failed' }, notes: [error.message])]
      end
    end

    # The report as terminal lines: one row per suite, the notes of each
    # suite that did not pass, then the gate's own line.
    def table(results)
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
       "qemu gate: #{overall(statuses)}; #{results.size} suites, #{pending} pending; " \
       "suites under #{SUITE_ACCELERATOR}, smoke under #{SMOKE_ACCELERATOR}"]
    end

    # A declared cell reported pending beside cells that ran did not run either: only a
    # suite whose every cell is pending may leave one pending.
    def held_to_its_cells(suite, reported)
      waiting = reported.cells.values.all?('pending') ? [] : suite.cells.select { |cell| reported.cells[cell] == 'pending' }
      missing = suite.cells - reported.cells.keys + waiting
      return reported if missing.empty?

      cells = reported.cells.merge(missing.to_h { |cell| [cell, 'not_run'] })
      result(suite.cells.to_h { |cell| [cell, cells.fetch(cell)] }.merge(cells),
             notes: [*reported.notes, *missing.map { |cell| "#{cell} was expected and did not run" }])
    end
    private_class_method :held_to_its_cells
  end
end
