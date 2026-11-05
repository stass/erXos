# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/carve_pl011_svd'

# The carve reads one pinned upstream file; any other bytes are refused before a
# register is read. The carved result is checked by hardware_test.rb through the
# generator, and the upstream file itself is not in the tree.
class CarvePl011SvdTest < Minitest::Test
  def test_other_bytes_are_refused
    ['', '<device/>', "<device>#{'x' * 100}</device>"].each do |bytes|
      error = assert_raises(Erx::Error) { Erx::CarvePl011.call(bytes) }
      assert_match(/not the pinned pico-sdk 1.5.1 file/, error.message)
    end
  end

  def test_register_names_lose_the_prefix_and_fields_keep_theirs
    assert_equal 'LCR_H', Erx::CarvePl011.strip_prefix('UARTLCR_H')
    assert_equal 'PERIPHID0', Erx::CarvePl011.strip_prefix('UARTPERIPHID0')
  end
end
