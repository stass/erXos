# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs test/erlang/erx_net_pkt_oracle_tests.erl: the network stack's pkt
# adapter, the codec fuzz targets' differential oracle, over hand-built headers.
class ErxNetPktOracleTest < Minitest::Test
  include ErxNetEunit

  def test_pkt_oracle_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_pkt_oracle_tests, extra: [:erx_net_pkt_oracle], pkt: true)
  end
end
