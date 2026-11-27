# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/faults'

# Erx::Faults, the QEMU harness's fault control (docs/design-recovery.md, layer 3): what a
# declaration admits and refuses, what an injection does, and the seeded fault of its one
# guard at run time, an injection the cell did not declare.
class FaultsTest < Minitest::Test
  Faults = Erx::Faults

  # A stand-in for the machine's QMP connection: records each call and answers {}.
  class Qmp
    attr_reader :calls

    def initialize = @calls = []
    def device_del(id) = (@calls << [:device_del, id]) && {}
    def eject(drive) = (@calls << [:eject, drive]) && {}
  end

  def declaration = Faults.declare([[:unplug, { device: 'usb-stick0' }], [:kill_domain, { domain: 'usb' }], [:power_cut]])

  def injector(qmp: Qmp.new, typed: [], cuts: [])
    Faults::Injector.new(declaration, qmp: qmp, type: ->(line) { typed << line }, cut: -> { cuts << :cut })
  end

  def test_a_declaration_of_ready_kinds_is_admitted_and_needs_what_its_actions_need
    assert declaration.needs_qmp?
    refute Faults.declare([[:power_cut], [:kill_domain, { domain: 'net' }]]).needs_qmp?
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
     [[:kill_domain, { domain: "usb'),os:cmd(\"x" }], /kill_domain's domain .* is not one it takes/],
     [[:eject, { drive: 7 }], /eject's drive 7 is not one it takes/],
     [:unplug, /a fault is \[kind, targets\]/]].each do |entry, message|
      assert_match(message, assert_raises(Faults::Refused) { Faults.declare([entry]) }.message)
    end
  end

  def test_a_fault_declared_twice_is_refused
    assert_raises(Faults::Refused) { Faults.declare([[:power_cut], [:power_cut]]) }
  end

  def test_each_ready_kind_does_its_action_and_is_recorded
    qmp = Qmp.new
    typed = []
    cuts = []
    faults = injector(qmp: qmp, typed: typed, cuts: cuts)
    faults.inject(:unplug, device: 'usb-stick0')
    faults.inject(:kill_domain, domain: 'usb')
    faults.inject(:power_cut)
    assert_equal [[:device_del, 'usb-stick0']], qmp.calls
    assert_equal 1, typed.size
    assert_match(/FkKilled=\[exit\(FkP,kill\)\|\|#\{pid:=FkP\}<-PcFind\('usb'\)\]/, typed.first)
    assert typed.first.end_with?(".\r")
    assert_equal [:cut], cuts
    assert_equal ['unplug device=usb-stick0', 'kill_domain domain=usb', 'power_cut'], faults.record
  end

  # The seeded fault is the injector without its check: the same injection must then do
  # its action, so the check, not the action's arguments, is what refuses it.
  def test_an_undeclared_fault_is_refused_and_nothing_is_done
    qmp = Qmp.new
    faults = injector(qmp: qmp)
    [[:unplug, { device: 'usb-stick1' }], [:eject, { drive: 'usb-stick0drive' }]].each do |kind, target|
      error = assert_raises(Faults::Refused) { faults.inject(kind, **target) }
      assert_match(/is not among the cell's declared faults/, error.message)
    end
    assert_empty qmp.calls
    assert_empty faults.record

    unguarded = Class.new(Faults::Injector) { def inject(kind, **target) = send(:run, Faults.action(Faults::Fault.new(kind: kind, target: target))) }
    unguarded.new(declaration, qmp: qmp, type: ->(_line) {}, cut: -> {}).inject(:unplug, device: 'usb-stick1')
    assert_equal [[:device_del, 'usb-stick1']], qmp.calls
  end

  def test_a_declaration_that_needs_qmp_refuses_an_injector_without_it
    assert_raises(Faults::Refused) { Faults::Injector.new(declaration, qmp: nil, type: ->(_line) {}, cut: -> {}) }
  end
end
