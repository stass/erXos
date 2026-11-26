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
  # A comparison session in QEMU (docs/design-bench.md, "A comparison session"):
  # `tools/erx bench NAME --systems LIST` boots, on one host, each listed
  # system's guest for the cells of NAME it has a counterpart for, one boot at a time,
  # in rounds: one in the landing form, three in the full, the order given in the first
  # round and turned by one system in each round after it. The session runs under HVF
  # unless a listed system's guest boots only under TCG (Genode's), and then wholly under
  # TCG, so its rows are set beside each other and never beside an HVF run. Each system
  # boots in a one-CPU form and in the landing boot's count, as its guest allows, and in
  # none another system of the boot cannot share; each boot is one run,
  # written as it ends, so a boot that fails loses nothing before it and the session
  # goes on with the next. A session gives no verdict: its runs are set side by side.
  module BenchSession
    # The systems that boot in QEMU; FreeBSD runs on the board only.
    SYSTEMS = %w[erxos l4re linux genode-hw].freeze
    ROUNDS = { 'landing' => 1, 'full' => 3 }.freeze
    # The accelerators a session may run under, the first that boots every system chosen.
    ACCELERATORS = %w[hvf tcg].freeze

    # One boot of a session: its round (from 0), its system's guest, the landing boot
    # whose cells it runs, those cells and its CPU count.
    Step = Data.define(:round, :system, :guest, :boot, :cells, :cpus)
    # The session's accelerator, its boots, and each [system, boot] whose cells no guest of
    # the system runs, which the session names instead of booting.
    Plan = Data.define(:accel, :steps, :missing)

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
    # whole, before any boot, when a system is not one, has no guest in QEMU, no
    # accelerator boots every guest the plan boots, the guests of a boot share no CPU
    # count, or a guest the plan boots refuses the profile, in the guest's own words. A
    # guest of a boot the benchmark does not ask is never asked.
    def plan(benchmark, systems:, profile:, guests:)
      rounds = ROUNDS.fetch(profile) { raise Error, "bench: profile #{profile} is not landing or full" }
      check_systems(systems, guests)
      guest = ->(system, boot) { guests.find { |candidate| candidate.system == system && candidate.boot == boot } }
      wanted = systems.product(benchmark.landing.keys).reject { |system, boot| cells(benchmark, boot, system).empty? }
      booted, missing = wanted.partition { |system, boot| guest.call(system, boot) }
      refusal = booted.lazy.filter_map { |system, boot| guest.call(system, boot).refusal(profile) }.first
      raise Error, "bench: #{refusal}" if refusal

      chosen = booted.map { |system, boot| guest.call(system, boot) }
      forms = forms(chosen)
      steps = order(systems, rounds: rounds).each_with_index.flat_map do |turned, round|
        turned.flat_map { |system| booted.select { |entry| entry.first == system } }.flat_map do |system, boot|
          picked = guest.call(system, boot)
          forms.fetch(picked).map do |cpus|
            Step.new(round: round, system: system, guest: picked, boot: boot, cells: cells(benchmark, boot, system),
                     cpus: cpus)
          end
        end
      end
      Plan.new(accel: accelerator(chosen), steps: steps, missing: missing)
    end

    # The first accelerator every guest of chosen boots under; refused, naming what each
    # system's guests allow, when there is none.
    def accelerator(chosen)
      found = ACCELERATORS.find { |accel| chosen.all? { |guest| guest.accelerators.include?(accel) } }
      return found if found

      allowed = chosen.group_by(&:system).map { |system, guests| "#{system} #{guests.map(&:accelerators).reduce(:&).join(',')}" }
      raise Error, "bench: no accelerator boots every listed system: #{allowed.join('; ')}"
    end

    # The CPU counts each guest of chosen boots in: its forms at its boot's landing count,
    # less a one-CPU form not every guest of the boot has. A boot's same-CPU cells are read
    # from the smallest count its guests share, so a guest booting only at a fixed count
    # (Genode's four) moves every guest of its boot there; a boot whose guests share no
    # count is refused.
    def forms(chosen)
      chosen.group_by(&:boot).flat_map do |boot, guests|
        cpus = BenchSuite::BOOTS.fetch(boot).cpus
        shared = guests.map { |guest| guest.forms(cpus) }.reduce(:&)
        raise Error, "bench: the #{boot} boot's guests share no CPU count: #{guests.map(&:system).join(', ')}" if shared.empty?

        guests.map { |guest| [guest, guest.forms(cpus) & [shared.min, cpus]] }
      end.to_h
    end
    private_class_method :accelerator, :forms

    def check_systems(systems, guests)
      raise Error, 'bench: --systems lists no system' if systems.empty?

      twice = systems.find { |system| systems.count(system) > 1 }
      raise Error, "bench: #{twice} is listed twice" if twice

      systems.each do |system|
        raise Error, "bench: #{system} has no guest in QEMU; it runs on the board only" if
          BenchRecord::SYSTEMS.include?(system) && !SYSTEMS.include?(system)
        raise Error, "bench: #{LineEscape.escape(system)} is not a system: #{SYSTEMS.join(', ')}" unless
          SYSTEMS.include?(system)

        raise Error, "bench: #{system} has no guest in QEMU" if guests.none? { |guest| guest.system == system }
      end
    end
    private_class_method :check_systems

    # The session's effects around its plan: each step's boot through BenchSystem on the
    # host host gives for the plan's environment kind (qemu-hvf or qemu-tcg), its record
    # written by write (BenchRecord.write's arguments, bound), and a note for each boot
    # that failed and each boot no guest runs.
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
        host = @host.call("qemu-#{plan.accel}")
        plan.steps.each { |step| boot(benchmark, step, host, result) }
        result.merge(notes: result.fetch(:notes).map { |note| "bench: #{LineEscape.escape(note)}" })
      end

      private

      # One step's boot, added to result: its run, the run directory written, and a note
      # for each line it refused; or a note saying why it failed. A replayed boot's
      # record is shown but not written: it is evidence of the run that recorded it.
      def boot(benchmark, step, host, result)
        recorded = BenchSystem.boot(step.guest, benchmark, cells: step.cells, cpus: step.cpus, host: host,
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
