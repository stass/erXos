# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of erx_gen_tcp's calls outside a connection,
# test/erlang/erx_gen_tcp_tests.erl: the calls it does not offer, and a host name
# resolved before the grant is asked; and listen, accept and controlling_process against
# stock's gen_tcp, over the stack's lo0 and the host's loopback
# (test/erlang/erx_gen_tcp_listen_tests.erl), with a loopback connection's TIME-WAIT
# checked against FreeBSD's 20 ms and a seeded fault in its lifetime.
class ErxGenTcpTest < Minitest::Test
  include ErxNetEunit

  def test_listen_accept_and_controlling_process_answer_as_stock_does
    assert_erx_net_eunit(:erx_gen_tcp_listen_tests)
  end

  # Every path built as one to a remote peer, so every step's context has a remote peer's
  # TIME-WAIT lifetime: a loopback connection's port stays held for 60 s instead of 20 ms.
  def test_seeded_full_time_wait_on_loopback_is_caught
    fault = ['broadcast => Broadcast, loopback => Loopback}.', 'broadcast => Broadcast, loopback => Loopback andalso false}.']
    output = refute_erx_net_eunit(:erx_gen_tcp_listen_tests, fault: { 'erx_net_frame' => fault })
    assert_match(/time_wait_test_/, output)
  end

  def test_unsupported_calls_and_host_names_pass_under_eunit
    assert_erx_net_eunit(:erx_gen_tcp_tests)
  end
end
