# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The USB bounds of abi/formats/usb.txt that the controller's structures in
# abi/formats/xhci.txt must hold: a route string, the slot context's 20 bits, names one
# hub port in each tier below the root in xhci_route_tier_bits, so a tier names every
# port up to usb_hub_ports_max and the route string holds usb_hub_depth_max tiers; and
# every endpoint a device may use has a device context index. Each case reads a copy
# of abi/.
class AbiUsbTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = Dir.mktmpdir('erx-abi-usb-')
    FileUtils.cp_r(File.join(ROOT, 'abi'), @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && @directory && File.directory?(@directory)
  end

  def test_the_route_string_holds_every_tier
    assert_empty route_violations(schema)
  end

  def test_every_endpoint_has_a_device_context_index
    assert_empty endpoint_violations(schema)
  end

  # A seeded fault: one tier more than the route string has bits for.
  def test_a_deeper_hub_bound_is_caught
    seed('abi/formats/usb.txt', 'limit usb_hub_depth_max u32 5', 'limit usb_hub_depth_max u32 6')
    refute_empty route_violations(schema)
  end

  # A seeded fault: a port count a tier's bits cannot name.
  def test_more_hub_ports_are_caught
    seed('abi/formats/usb.txt', 'limit usb_hub_ports_max u32 15', 'limit usb_hub_ports_max u32 16')
    refute_empty route_violations(schema)
  end

  # A seeded fault: a route string one tier short.
  def test_a_shorter_route_string_is_caught
    seed('abi/formats/xhci.txt', 'bits route_string 0 19', 'bits route_string 0 15')
    refute_empty route_violations(schema)
  end

  # A seeded fault: more endpoints than a device context has.
  def test_more_endpoints_are_caught
    seed('abi/formats/usb.txt', 'limit usb_endpoints_max u32 8', 'limit usb_endpoints_max u32 32')
    refute_empty endpoint_violations(schema)
  end

  private

  def schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: @directory))

  def limit(abi, name) = abi.constants.fetch(name).value

  def route_violations(abi)
    tier = limit(abi, 'xhci_route_tier_bits')
    ports = limit(abi, 'usb_hub_ports_max')
    depth = limit(abi, 'usb_hub_depth_max')
    width = route_string_width(abi)
    violations = []
    violations << "usb_hub_ports_max #{ports} needs more than #{tier} bits" if ports > (1 << tier) - 1
    violations << "#{depth} tiers of #{tier} bits exceed the route string's #{width}" if depth * tier > width
    violations
  end

  def route_string_width(abi)
    route = abi.types.fetch('erx_xhci_slot_context').fields.find { |field| field.name == 'route' }
    bits = route.bits.find { |item| item.fetch(:name) == 'route_string' }
    bits.fetch(:high) - bits.fetch(:low) + 1
  end

  # Device context index 0 is the slot's; EP0 and every other endpoint take one of the rest.
  def endpoint_violations(abi)
    endpoints = limit(abi, 'usb_endpoints_max')
    indexes = limit(abi, 'xhci_device_contexts') - 1
    endpoints <= indexes ? [] : ["usb_endpoints_max #{endpoints} exceeds #{indexes} device context indexes"]
  end

  def seed(relative, original, replacement)
    path = File.join(@directory, relative)
    source = File.read(path)
    assert_equal 1, source.scan(original).size, "the seed must edit exactly one place: #{original}"
    File.write(path, source.sub(original, replacement))
  end
end
