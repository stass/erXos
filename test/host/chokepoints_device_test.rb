# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'
require_relative '../../tools/lib/erx/hardware'

# The device group's own cases: a runtime reaches a register window only through
# erx_device's table-driven accesses, so the per-peripheral accessors tools/gen_hw.rb
# generates from the SVD files have no caller in the runtime.
class ChokepointsDeviceTest < Minitest::Test
  include ChokepointsHelper

  RUNTIME_FILE = 'otp/erts/emulator/beam/seeded.c'
  BYPASS = "#include <erx/hw/pl011.h>\nvoid f(erx_mmio_t d) { erx_pl011_dr_write(d, 65); }\n"

  def test_a_generated_peripheral_accessor_in_the_runtime_fails
    found = evaluate(Rules::ACTIVE, { RUNTIME_FILE => BYPASS })
    assert_equal %w[device-peripheral-accessors device-peripheral-headers], found.map(&:rule).uniq.sort
  end

  # A peripheral header is named by its path below include/, in any case, so a header of the
  # same file name elsewhere is not one.
  def test_only_the_generated_header_path_is_a_peripheral_include
    found = ->(text) { evaluate([rule('device-peripheral-headers')], { RUNTIME_FILE => text }) }
    refute_empty found.call("#include \"erx/hw/PL011.h\"\n")
    assert_empty found.call("#include <drivers/pl011.h>\n")
    assert_empty found.call("#include \"pl011.h\"\n")
  end

  # The checked names come from the generator, so a register or device added to an SVD file
  # is covered without an edit here, and the generated headers that define them pass.
  def test_every_generated_symbol_is_caught_outside_its_generated_header
    rules = [rule('device-peripheral-accessors'), rule('device-peripheral-headers')]
    plan = Erx::Hardware.output_plan(root: ROOT)
    Erx::Hardware.devices(root: ROOT).each do |device|
      header = Erx::Hardware.device_header_path(device)
      assert_empty evaluate(rules, { header => plan.fetch(header) })
      Erx::Hardware.generated_symbols(device).each do |symbol|
        refute_empty evaluate(rules, { RUNTIME_FILE => "long x = #{symbol};\n" }), symbol
      end
    end
  end
end
