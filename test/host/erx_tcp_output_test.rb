# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of TCP output (test/erlang/erx_tcp_output_tests.erl): windows, Nagle,
# silly-window avoidance, persist, FIN and RST, SACK retransmission, options and credit.
class ErxTcpOutputTest < Minitest::Test
  include ErxNetEunit

  def test_output_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_output_tests)
  end
end
