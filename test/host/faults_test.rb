# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/faults'

# Erx::Faults, the QEMU harness's fault control (docs/design-recovery.md, layer 3): what a
# declaration admits and refuses, what an injection does, and its guard at run time, an
# injection the cell did not declare, with that guard's seeded fault.
class FaultsTest < Minitest::Test
  Faults = Erx::Faults

  # A stand-in for the machine's QMP connection: records each call and answers {}.
  class Qmp
    attr_reader :calls

    def initialize = @calls = []
    def device_del(id) = (@calls << [:device_del, id]) && {}
    def eject(drive) = (@calls << [:eject, drive]) && {}
  end

  # The seeded fault of the injector's guard: a fault counts as declared when its kind is.
  class KindOnlyInjector < Faults::Injector
    private

    def declared?(fault) = @declaration.faults.any? { |declared| declared.kind == fault.kind }
  end

  DECLARED = [[:unplug, { device: 'usb-stick0' }], [:kill_domain, { domain: :'usb@erxos' }], [:power_cut]].freeze
  UNDECLARED = [[:unplug, { device: 'usb-stick1' }], [:kill_domain, { domain: 'net@erxos' }],
                [:eject, { drive: 'usb-stick0drive' }]].freeze

  def declaration = Faults.declare(DECLARED)

  def injector(qmp: Qmp.new, typed: [], answer: '{fault_killed,1}', cuts: [], type: Faults::Injector)
    type.new(declaration, qmp: qmp, type: ->(line) { typed << line && answer }, cut: -> { cuts << :cut })
  end

  def test_a_declaration_of_ready_kinds_is_admitted_and_needs_what_its_actions_need
    assert declaration.needs_qmp?
    refute Faults.declare([[:power_cut], [:kill_domain, { domain: 'net@erxos' }]]).needs_qmp?
  end

  def test_a_kind_outside_the_set_is_refused_naming_it
    error = assert_raises(Faults::Refused) { Faults.declare([[:unplug, { device: 'a' }], [:melt, {}]]) }
    assert_match(/:melt is not a fault kind/, error.message)
  end

  def test_a_kind_not_shown_on_qemu_or_not_written_is_refused_naming_its_status
    assert_match(/block_stall is unverified/,
                 assert_raises(Faults::Refused) { Faults.declare([[:block_stall, { drive: 'data' }]]) }.message)
    assert_match(/line_silent is unwritten/,
                 assert_raises(Faults::Refused) { Faults.declare([[:line_silent, { chardev: 'bt' }]]) }.message)
  end

  def test_a_missing_extra_or_malformed_target_is_refused
    [[[:unplug], /unplug takes device, not/],
     [[:power_cut, { device: 'a' }], /power_cut takes no targets/],
     [[:kill_domain, { domain: "usb@erxos'),os:cmd(\"x" }], /kill_domain's domain .* is not one it takes/],
     [[:kill_domain, { domain: 'usb' }], /kill_domain's domain "usb" is not one it takes/],
     [[:eject, { drive: 7 }], /eject's drive 7 is not one it takes/],
     [:unplug, /a fault is \[kind, targets\]/]].each do |entry, message|
      assert_match(message, assert_raises(Faults::Refused) { Faults.declare([entry]) }.message)
    end
  end

  def test_no_fault_is_made_past_its_checks
    assert_raises(Faults::Refused) { Faults::Fault.new(kind: :kill_domain, target: { domain: "x'),halt()" }) }
  end

  def test_a_fault_declared_twice_is_refused
    assert_raises(Faults::Refused) { Faults.declare([[:power_cut], [:power_cut]]) }
  end

  def test_each_ready_kind_does_its_action_and_is_recorded
    qmp = Qmp.new
    typed = []
    cuts = []
    faults = injector(qmp: qmp, typed: typed, cuts: cuts)
    faults.inject(:unplug, device: :'usb-stick0')
    faults.inject(:kill_domain, domain: 'usb@erxos')
    faults.inject(:power_cut)
    assert_equal [[:device_del, 'usb-stick0']], qmp.calls
    assert_equal [:cut], cuts
    assert_equal ['unplug device=usb-stick0', 'kill_domain domain=usb@erxos', 'power_cut'], faults.record
    line = typed.fetch(0)
    assert line.start_with?('(fun()->PcFind=fun(PcN)->')
    assert line.end_with?("[exit(P,kill)||\#{pid:=P}<-PcFind('usb@erxos')])}]) end)().\r")
  end

  def test_a_kill_that_killed_nothing_is_refused_and_recorded_as_tried
    faults = injector(answer: '{fault_killed,0}')
    assert_match(/kill_domain domain=usb@erxos killed nothing/,
                 assert_raises(Faults::Refused) { faults.inject(:kill_domain, domain: 'usb@erxos') }.message)
    assert_equal ['kill_domain domain=usb@erxos'], faults.record
  end

  # Every undeclared fault is refused with nothing done; the seeded guard, matching kinds
  # only, lets each through to its action, so the guard is what refuses them.
  def test_an_undeclared_fault_is_refused_and_nothing_is_done
    qmp = Qmp.new
    typed = []
    faults = injector(qmp: qmp, typed: typed)
    UNDECLARED.each do |kind, target|
      error = assert_raises(Faults::Refused) { faults.inject(kind, **target) }
      assert_match(/is not among the cell's declared faults/, error.message)
    end
    assert_empty qmp.calls
    assert_empty typed
    assert_empty faults.record

    seeded = injector(qmp: qmp, typed: typed, type: KindOnlyInjector)
    seeded.inject(:unplug, device: 'usb-stick1')
    seeded.inject(:kill_domain, domain: 'net@erxos')
    assert_equal [[:device_del, 'usb-stick1']], qmp.calls
    assert_match(/PcFind\('net@erxos'\)/, typed.fetch(0))
  end

  def test_a_declaration_that_needs_qmp_refuses_an_injector_without_it
    assert_raises(Faults::Refused) { Faults::Injector.new(declaration, qmp: nil, type: ->(_line) {}, cut: -> {}) }
  end
end
