# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs test/erlang/erx_tcp_cc_tests.erl: the congestion modules, NewReno and CUBIC, driven
# through the callbacks a connection makes.
class ErxTcpCcTest < Minitest::Test
  include ErxNetEunit

  def test_congestion_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_cc_tests)
  end
end
