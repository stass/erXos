# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'bench_side_by_side'
require_relative 'bench_suite'
require_relative 'bench_system'
require_relative 'error'
require_relative 'line_escape'

module Erx
  # A comparison session in QEMU under HVF (docs/design-bench.md, "A comparison
  # session"): `tools/erx bench NAME --systems LIST` boots, on one host, each listed
  # system's guest for the cells of NAME it has a counterpart for, one boot at a time,
  # in rounds: one in the landing form, three in the full, the order given in the first
  # round and turned by one system in each round after it. Each system boots in a one-CPU
  # form and in the landing boot's count, as its guest allows; each boot is one run,
  # written as it ends, so a boot that fails loses nothing before it and the session
  # goes on with the next. A session gives no verdict: its runs are set side by side.
  module BenchSession
    # The systems that boot in QEMU under HVF; FreeBSD runs on the board only.
    SYSTEMS = %w[erxos l4re linux].freeze
    ROUNDS = { 'landing' => 1, 'full' => 3 }.freeze
    KIND = 'qemu-hvf'

    # One boot of a session: its round (from 0), its system's guest, the landing boot
    # whose cells it runs, those cells and its CPU count.
    Step = Data.define(:round, :system, :guest, :boot, :cells, :cpus)
    # The session's boots, and each [system, boot] whose cells no guest of the system
    # runs, which the session names instead of booting.
    Plan = Data.define(:steps, :missing)

    module_function

    # Each round's order of systems: as given in the first, turned by one in each after.
    def order(systems, rounds:) = (0...rounds).map { |round| systems.rotate(round) }

    # The cells of boot a system runs: all of erXos's own, and of another system those
    # it has a counterpart for (docs/design-bench.md, "Counterparts").
    def cells(benchmark, boot, system)
      landing = benchmark.landing.fetch(boot, [])
      return landing if system == 'erxos'

      landing.select { |cell| benchmark.operations.fetch(cell.operation).counterparts.key?(system) }
    end

    # The session's plan for benchmark over systems at profile with guests, refused
    # whole, before any boot, when a system is not one, has no guest under HVF, or has
    # a guest that refuses the profile, in the guest's own words.
    def plan(benchmark, systems:, profile:, guests:)
      rounds = ROUNDS.fetch(profile) { raise Error, "bench: profile #{profile} is not landing or full" }
      check_systems(systems, guests, profile)
      guest = ->(system, boot) { guests.find { |candidate| candidate.system == system && candidate.boot == boot } }
      wanted = systems.product(benchmark.landing.keys).reject { |system, boot| cells(benchmark, boot, system).empty? }
      booted, missing = wanted.partition { |system, boot| guest.call(system, boot) }
      steps = order(systems, rounds: rounds).each_with_index.flat_map do |turned, round|
        turned.flat_map { |system| booted.select { |entry| entry.first == system } }.flat_map do |system, boot|
          chosen = guest.call(system, boot)
          chosen.forms(BenchSuite::BOOTS.fetch(boot).cpus).map do |cpus|
            Step.new(round: round, system: system, guest: chosen, boot: boot, cells: cells(benchmark, boot, system),
                     cpus: cpus)
          end
        end
      end
      Plan.new(steps: steps, missing: missing)
    end

    def check_systems(systems, guests, profile)
      raise Error, 'bench: --systems lists no system' if systems.empty?

      twice = systems.find { |system| systems.count(system) > 1 }
      raise Error, "bench: #{twice} is listed twice" if twice

      systems.each do |system|
        raise Error, "bench: #{system} has no guest under HVF; it runs on the board only" if
          BenchRecord::SYSTEMS.include?(system) && !SYSTEMS.include?(system)
        raise Error, "bench: #{LineEscape.escape(system)} is not a system: #{SYSTEMS.join(', ')}" unless
          SYSTEMS.include?(system)

        own = guests.select { |guest| guest.system == system }
        raise Error, "bench: #{system} has no guest under HVF yet" if own.empty?

        refusal = own.filter_map { |guest| guest.refusal(profile) }.first
        raise Error, "bench: #{refusal}" if refusal
      end
    end
    private_class_method :check_systems

    # The session's effects around its plan: each step's boot through BenchSystem, its
    # record written by write (BenchRecord.write's arguments, bound), and a note for
    # each boot that failed and each boot no guest runs.
    class Run
      def initialize(guests:, host:, write:, load:)
        @guests = guests
        @host = host
        @write = write
        @load = load
      end

      # The runs booted (BenchSideBySide::Run), the run directories written, the boots
      # that failed, and the notes, each escaped for the terminal.
      def call(benchmark, systems:, profile:)
        plan = BenchSession.plan(benchmark, systems: systems, profile: profile, guests: @guests)
        result = { runs: [], written: [], failed: [], notes: plan.missing.map do |system, boot|
          "#{system}: no guest runs the #{boot} boot's cells, so they are not booted"
        end }
        plan.steps.each { |step| boot(benchmark, step, result) }
        result.merge(notes: result.fetch(:notes).map { |note| "bench: #{LineEscape.escape(note)}" })
      end

      private

      # One step's boot, added to result: its run, the run directory written, and a note
      # for each line it refused; or a note saying why it failed. A replayed boot's
      # record is shown but not written: it is evidence of the run that recorded it.
      def boot(benchmark, step, result)
        recorded = BenchSystem.boot(step.guest, benchmark, cells: step.cells, cpus: step.cpus, host: @host,
                                                           started_by: 'manual', load: @load)
        result.fetch(:runs) << BenchSideBySide::Run.new(round: step.round, record: recorded.record)
        result.fetch(:written) << @write.call(recorded.record, recorded.logs) unless recorded.record.run.replayed?
        result.fetch(:notes).concat(recorded.refused.map { |reason| "#{label(step)}: refused: #{reason}" })
      rescue Error, SystemCallError => e
        result.fetch(:failed) << label(step)
        result.fetch(:notes) << "#{label(step)} failed: #{e.message}"
      end

      def label(step) = "#{step.system} #{step.cpus}-CPU boot of round #{step.round + 1}"
    end
  end
end
