# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_session'

# A comparison session (docs/design-bench.md, "A comparison session"): each listed
# system's guest boots the cells it has a counterpart for, one system after another, in
# rounds of turning order, in a one-CPU and a four-CPU form, and each boot is one run.
class BenchSessionTest < Minitest::Test
  Session = Erx::BenchSession
  Record = Erx::BenchRecord

  # A guest that boots nothing: each boot answers its asked cells unsupported, or raises
  # when told to fail.
  class Guest
    attr_reader :system, :boot, :calls

    attr_reader :accelerators

    def initialize(system, boot: 'native', one_cpu: false, profiles: %w[landing full], fail: false, accelerators: %w[hvf tcg],
                   fixed: nil)
      @system, @boot, @one_cpu, @profiles, @fail, @accelerators, @fixed = system, boot, one_cpu, profiles, fail, accelerators, fixed
      @calls = []
    end

    def forms(cpus) = @fixed || (@one_cpu ? [1] : [1, cpus])
    def refusal(profile) = ("#{system} offers no #{profile} profile" unless @profiles.include?(profile))

    def call(benchmark, cells:, cpus:, accel:)
      @calls << [cells.map(&:operation), cpus, accel]
      raise Erx::Error, "the guest stopped \e[31m early" if @fail

      Erx::BenchSystem::Booted.new(
        clock: {}, refused: [], environment: { 'memory_mib' => 512 }, subject: { 'image_sha256' => '0' * 64 },
        logs: [], reused_from: nil,
        cells: cells.map do |cell|
          Record::Cell.new(benchmark: benchmark.name, operation: cell.operation, status: 'unsupported', reason: 'test',
                           conditions: Record::Conditions.new(load: cell.load, placement: cell.placement,
                                                              parameters: cell.parameters, clock: 'counter', batch: 1),
                           profile: Record::Profile.new(name: 'fast', warmup: 0, samples: 1, runs: 1),
                           counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 }, detail: {})
        end
      )
    end
  end

  def wake = Erx::BenchSuite.benchmark('wake')

  def host = ->(kind) { Erx::BenchSystem::Host.new(kind: kind, model: 'Mac16,10', cpus: 12, revision: 'a' * 40, dirty: false) }

  # A system whose guest boots only under TCG, at one fixed CPU count (Genode's), makes
  # the whole session TCG at that count: every system boots there, so its rows are set
  # beside erXos's own TCG rows of the same CPUs and never beside an HVF run.
  def test_a_tcg_only_guest_makes_the_session_tcg_at_its_cpu_count
    posix = Erx::BenchSuite.benchmark('posix')
    genode = Guest.new('genode-hw', boot: 'posix', accelerators: %w[tcg], fixed: [4])
    erxos = Guest.new('erxos', boot: 'posix')
    plan = Session.plan(posix, systems: %w[erxos genode-hw], profile: 'landing', guests: [erxos, genode])
    assert_equal ['tcg', [%w[erxos 4], %w[genode-hw 4]]], [plan.accel, plan.steps.map { |step| [step.system, step.cpus.to_s] }]
    alone = Session.plan(posix, systems: %w[erxos], profile: 'landing', guests: [erxos, genode])
    assert_equal ['hvf', [1, 4]], [alone.accel, alone.steps.map(&:cpus)]
    linux = Guest.new('linux', boot: 'posix', accelerators: %w[hvf])
    error = assert_raises(Erx::Error) do
      Session.plan(posix, systems: %w[linux genode-hw], profile: 'landing', guests: [linux, genode])
    end
    assert_match(/no accelerator boots every listed system: linux hvf; genode-hw tcg/, error.message)
    written = []
    result = Session::Run.new(guests: [erxos, genode], host: host, write: ->(record, _) { written << record.environment.name },
                              load: -> {}).call(posix, systems: %w[erxos genode-hw], profile: 'landing')
    assert_equal %w[qemu-tcg-Mac16,10-4cpu-erxos qemu-tcg-Mac16,10-4cpu-genode-hw], written
    assert_equal [[4, 'tcg']], genode.calls.map { |_, cpus, accel| [cpus, accel] }
    assert_empty result.fetch(:failed)
  end

  def test_each_round_turns_the_order_by_one_system
    systems = %w[erxos l4re linux]
    assert_equal [systems], Session.order(systems, rounds: 1)
    full = Session.order(systems, rounds: Session::ROUNDS.fetch('full'))
    assert_equal [systems, %w[l4re linux erxos], %w[linux erxos l4re]], full
    # In the full form each system boots once in each position.
    assert(full.transpose.all? { |position| position.sort == systems.sort })
  end

  # erXos boots every cell of its boot; Linux only those it has a counterpart for. A boot
  # with cells and no guest of the system is left out, and said so.
  def test_the_plan_boots_each_system_for_its_counterparts_in_both_forms
    guests = [Guest.new('erxos'), Guest.new('linux')]
    plan = Session.plan(wake, systems: %w[erxos linux], profile: 'landing', guests: guests)
    steps = plan.steps.map { |step| [step.round, step.system, step.boot, step.cpus, step.cells.map(&:operation)] }
    erxos = %w[wake-same-cpu wake-cross-cpu trigger-take park-deadline]
    linux = %w[wake-same-cpu wake-cross-cpu park-deadline]
    assert_equal [[0, 'erxos', 'native', 1, erxos], [0, 'erxos', 'native', 4, erxos],
                  [0, 'linux', 'native', 1, linux], [0, 'linux', 'native', 4, linux]], steps
    assert_equal [%w[erxos xdomain]], plan.missing
    one_cpu = Session.plan(wake, systems: %w[linux], profile: 'landing', guests: [Guest.new('linux', one_cpu: true)])
    assert_equal [1], one_cpu.steps.map(&:cpus)
  end

  # Genode runs every posix row through its C library and its own services
  # (docs/design-bench.md, "The operations and their paths"), so its posix boot asks every
  # cell erXos's does.
  def test_genode_boots_every_posix_cell
    posix = Erx::BenchSuite.benchmark('posix')
    guests = [Guest.new('erxos', boot: 'posix'), Guest.new('genode-hw', boot: 'posix')]
    plan = Session.plan(posix, systems: %w[erxos genode-hw], profile: 'landing', guests: guests)
    cells = plan.steps.group_by(&:system).transform_values { |steps| steps.map { |step| step.cells.map(&:operation) } }
    refute_empty cells.fetch('genode-hw')
    assert_equal cells.fetch('erxos'), cells.fetch('genode-hw')
  end

  def test_systems_are_refused_before_any_boot
    guests = [Guest.new('erxos')]
    refusal = ->(systems, profile: 'landing') { assert_raises(Erx::Error) { Session.plan(wake, systems: systems, profile: profile, guests: guests) }.message }
    assert_match(/freebsd has no guest in QEMU/, refusal.call(%w[erxos freebsd]))
    assert_match(/plan9 is not a system/, refusal.call(%w[plan9]))
    assert_match(/linux has no guest/, refusal.call(%w[erxos linux]))
    assert_match(/twice/, refusal.call(%w[erxos erxos]))
    assert_match(/no system/, refusal.call([]))
    assert_match(/profile/, refusal.call(%w[erxos], profile: 'quick'))
    landing_only = [Guest.new('erxos', profiles: %w[landing])]
    error = assert_raises(Erx::Error) { Session.plan(wake, systems: %w[erxos], profile: 'full', guests: landing_only) }
    assert_equal 'bench: erxos offers no full profile', error.message
  end

  # Only the guests of the boots the plan makes are asked whether they refuse: a guest of
  # a boot the benchmark does not have, which would refuse, never stops the session.
  def test_only_the_guests_the_plan_boots_are_asked_to_refuse
    nullcall = Erx::BenchSuite.benchmark('nullcall')
    guests = [Guest.new('erxos'), Guest.new('linux'), Guest.new('linux', boot: 'xdomain', profiles: [])]
    plan = Session.plan(nullcall, systems: %w[erxos linux], profile: 'landing', guests: guests)
    assert_equal [%w[erxos native], %w[linux native]], plan.steps.map { |step| [step.system, step.boot] }.uniq
    error = assert_raises(Erx::Error) do
      Session.plan(Erx::BenchSuite.benchmark('xdomain'), systems: %w[erxos linux], profile: 'landing',
                                                         guests: guests + [Guest.new('erxos', boot: 'xdomain')])
    end
    assert_equal 'bench: linux offers no landing profile', error.message
  end

  # Each boot is written as it ends, so a guest that fails leaves the runs before it and
  # the session goes on with the next.
  def test_each_boot_is_one_run_and_a_failed_boot_does_not_end_the_session
    erxos, linux = Guest.new('erxos'), Guest.new('linux', fail: true)
    written = []
    write = ->(record, logs) { written << [record.environment.name, logs] && "run-#{written.size}" }
    loads = [0.5, 0.75].cycle
    result = Session::Run.new(guests: [linux, erxos], host: host, write: write, load: -> { loads.next })
                         .call(wake, systems: %w[linux erxos], profile: 'landing')
    assert_equal [['qemu-hvf-Mac16,10-1cpu-erxos', []], ['qemu-hvf-Mac16,10-4cpu-erxos', []]], written
    assert_equal [[1, 'hvf'], [4, 'hvf']], erxos.calls.map { |_, cpus, accel| [cpus, accel] }
    assert_equal 2, linux.calls.size
    assert_equal %w[run-1 run-2], result.fetch(:written)
    assert_equal ['linux 1-CPU boot of round 1', 'linux 4-CPU boot of round 1'], result.fetch(:failed)
    record = result.fetch(:runs).first.record
    assert_equal ['manual', [0.5, 0.75], 'a' * 40, 512], [record.run.started_by, record.run.load, record.subject.revision,
                                                          record.environment.details.fetch('memory_mib')]
    notes = result.fetch(:notes)
    assert(notes.any? { |note| note.include?('linux 1-CPU boot') && note.include?('the guest stopped') })
    refute(notes.any? { |note| note.include?("\e") })
    assert(notes.any? { |note| note.include?('xdomain') })
  end
end
