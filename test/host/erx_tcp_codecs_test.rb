# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the TCP codec and sequence lifting,
# test/erlang/erx_tcp_wire_tests.erl and erx_tcp_seq_tests.erl.
class ErxTcpCodecsTest < Minitest::Test
  include ErxNetEunit

  def test_tcp_wire_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_wire_tests)
  end

  def test_tcp_seq_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_seq_tests)
  end
end
