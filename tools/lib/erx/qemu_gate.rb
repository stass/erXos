# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'etc'
require_relative 'bounded_file'
require_relative 'declaration_files'
require_relative 'error'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'qemu_reuse'
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
    # Every suite runs under this accelerator here; a cell the gate moves to a
    # remote host runs under QemuCells::REMOTE_ACCELERATOR there.
    SUITE_ACCELERATOR = QemuCells::LOCAL_ACCELERATOR
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

    # What a suite sees: the repository, the build job count, and where its
    # cells boot (QemuCells::Placement), which it hands its run.
    Context = Data.define(:root, :jobs, :placement) do
      def initialize(root:, jobs:, placement: QemuCells::HERE) = super
    end

    # A remote host for the landing gate: a suite that declares offload moves
    # its multi-CPU cells there while this host's one-minute load average is
    # at least busy_load (QemuCells.placement).
    Offload = Data.define(:remote, :busy_load) do
      def initialize(remote:, busy_load:)
        raise Error, 'an offload names a QemuRemote::Host' unless remote.is_a?(QemuRemote::Host)
        raise Error, 'an offload\'s busy load is a number at least 0' unless busy_load.is_a?(Numeric) && busy_load >= 0

        super
      end
    end

    # Cells map a name to one of CELL_STATUSES; a status outside it cannot be built.
    # Boots is how the suite's boots went (QemuReuse::Boots): reuse is not a
    # cell status, because a cell over a reused boot is still judged by
    # today's code, from the stored log; the table names every reused log.
    Result = Data.define(:cells, :notes, :boots) do
      def initialize(cells:, notes:, boots: QemuReuse::NO_BOOTS)
        unknown = cells.values - CELL_STATUSES
        raise Error, "QEMU suites: unknown cell status #{unknown.first.inspect}" unless unknown.empty?

        super(cells: cells.dup.freeze, notes: notes.dup.freeze, boots: boots)
      end
    end

    # A suite's cells are the ones it must report, as named here; the gate
    # holds it to them where it placed them (QemuGate.run), so a run that
    # leaves one out cannot pass. offload declares that its multi-CPU cells
    # may move to a remote host: its harness places them and they pass under
    # TCG there in a gate's time (docs/design-build.md, "Placing cells").
    Suite = Data.define(:name, :cells, :run, :offload) do
      def initialize(name:, cells:, run:, offload: false)
        valid = cells.is_a?(Array) && !cells.empty? && cells.all?(String) && cells.uniq.size == cells.size
        raise Error, "QEMU suites: #{name} declares no list of distinct cells" unless valid
        raise Error, "QEMU suites: #{name} is not a callable" unless run.respond_to?(:call)

        raise Error, "QEMU suites: #{name} declares offload as neither true nor false" unless [true, false].include?(offload)

        super(name: name, cells: cells.dup.freeze, run: run, offload: offload)
      end
    end

    SUITE_FILES = DeclarationFiles.new('QEMU suites')
    private_constant :SUITE_FILES

    module_function

    # Each file under qemu_suites/ calls this exactly once, with the cells
    # its run reports; load_suites checks both as it builds each Suite.
    def declare_suite(cells:, run:, offload: false)
      SUITE_FILES.declare([cells, run, offload])
    end

    # The suites declared in directory, sorted by name. Public so the tests
    # can feed it malformed directories.
    def load_suites(directory)
      SUITE_FILES.load_all(directory).map do |name, (cells, run, offload)|
        Suite.new(name: name, cells: cells, run: run, offload: offload)
      end.freeze
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
    # With reuse, a QemuReuse::Session, each suite runs inside it: its
    # reusable boots that passed before are reused, and its fresh boots are
    # recorded only when the suite passed; a suite that did not pass forgets
    # the boots it reused, so its next run boots them again.
    #
    # Each suite is placed (QemuCells.placement) from this host's load as it
    # starts, which host_load reads (nil when unknown, which places every
    # cell here, one after another), and is held to its cells as placed. Its
    # multi-CPU cells move only with offload, an Offload, and only when the
    # suite declares offload.
    def run(suites:, context:, reuse: nil, offload: nil, host_load: -> { one_minute_load }, cores: Etc.nprocessors)
      suites.to_h do |suite|
        placed = context.with(placement: placement(suite, offload: offload, load: host_load.call, cores: cores))
        next [suite.name, judged(suite, placed)] unless reuse

        result, boots = reuse.suite(suite.name) { judged(suite, placed) }
        [suite.name, result.with(boots: boots.close(passed: status(result) == 'passed'))]
      end
    end

    def placement(suite, offload:, load:, cores:)
      return QemuCells::HERE if load.nil?

      QemuCells.placement(cells: suite.cells, remote: offload&.remote, offload: suite.offload, load: load,
                          busy_load: offload&.busy_load, cores: cores)
    end
    private_class_method :placement

    # This host's one-minute load average, or nil when it cannot be read.
    def one_minute_load
      text = if File.readable?('/proc/loadavg') then File.read('/proc/loadavg')
             else IO.popen(%w[sysctl -n vm.loadavg], err: File::NULL, &:read)
             end
      Float(text.to_s[/\d+(?:\.\d+)?/] || 'unknown', exception: false)
    rescue SystemCallError
      nil
    end

    def judged(suite, context)
      remote = context.placement.remote
      held_to_its_cells(suite, suite.run.call(context), suite.cells.map { |cell| QemuCells.placed_name(cell, remote) })
    rescue Error => error
      result({ 'run' => 'failed' }, notes: [error.message])
    end
    private_class_method :judged

    # The report as terminal lines: one row per suite, with how many of its
    # boots were reused; the notes of each suite that did not pass; each
    # reused log and each reuse diagnostic; then the gate's own line, which
    # counts the boots reused.
    # With remote, the host the gate may move cells to, the last line names it.
    def table(results, remote: nil)
      rows = results.map do |name, entry|
        cells = entry.cells.map { |cell, value| "#{cell} #{value}" }.join(', ')
        "#{name.ljust(16)} #{status(entry).ljust(11)} #{cells}#{reuse_mark(entry.boots)}"
      end
      notes = results.flat_map do |name, entry|
        status(entry) == 'passed' ? [] : entry.notes.map { |note| "#{name}: #{note}" }
      end
      reused_lines = results.flat_map { |name, entry| entry.boots.reused.map { |log| "#{name}: reused from #{log}" } }
      reuse_diagnostics = results.flat_map { |name, entry| entry.boots.diagnostics.map { |text| "#{name}: #{text}" } }
      statuses = results.values.map { |entry| status(entry) }
      pending = statuses.count('pending')
      reused = results.values.sum { |entry| entry.boots.reused.size }
      [*rows, *notes, *reused_lines, *reuse_diagnostics,
       "qemu gate: #{overall(statuses)}; #{results.size} suites, #{pending} pending; " \
       "#{reused} boots reused from earlier passes; " \
       "suites under #{SUITE_ACCELERATOR}, smoke under #{SMOKE_ACCELERATOR}" \
       "#{remote ? "; moved cells under #{QemuCells::REMOTE_ACCELERATOR} on #{remote.destination}" : ''}"]
    end

    def reuse_mark(boots)
      return '' if boots.reused.empty?

      " (#{boots.reused.size} of #{boots.reused.size + boots.fresh} boots reused)"
    end
    private_class_method :reuse_mark

    # expected is the suite's cells as placed. A declared cell reported pending beside
    # cells that ran did not run either: only a suite whose every cell is pending may
    # leave one pending.
    def held_to_its_cells(suite, reported, expected = suite.cells)
      waiting = reported.cells.values.all?('pending') ? [] : expected.select { |cell| reported.cells[cell] == 'pending' }
      missing = expected - reported.cells.keys + waiting
      return reported if missing.empty?

      cells = reported.cells.merge(missing.to_h { |cell| [cell, 'not_run'] })
      result(expected.to_h { |cell| [cell, cells.fetch(cell)] }.merge(cells),
             notes: [*reported.notes, *missing.map { |cell| "#{cell} was expected and did not run" }])
    end
    private_class_method :held_to_its_cells
  end
end
