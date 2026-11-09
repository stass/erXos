# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of erx_gen_tcp's calls outside a connection,
# test/erlang/erx_gen_tcp_tests.erl: the calls it does not offer, and a host name
# resolved before the grant is asked.
class ErxGenTcpTest < Minitest::Test
  include ErxNetEunit

  def test_unsupported_calls_and_host_names_pass_under_eunit
    assert_erx_net_eunit(:erx_gen_tcp_tests)
  end
end
