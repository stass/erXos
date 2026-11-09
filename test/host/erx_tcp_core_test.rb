# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the TCP connection core: the step's dispatch and settling, user
# requests, timer expirations and the send buffer (test/erlang/erx_tcp_tests.erl).
class ErxTcpCoreTest < Minitest::Test
  include ErxNetEunit

  def test_core_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_tests)
  end
end
