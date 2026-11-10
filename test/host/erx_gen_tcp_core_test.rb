# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the socket protocol's pure parts,
# test/erlang/erx_gen_tcp_core_tests.erl, and two seeded failures: of the credit rule,
# a socket process that grants again only once all it granted is pushed, so the
# connection idles while each grant travels; and of the end in passive mode, a socket
# process that drops what it holds and the error once the connection is gone, so an
# owner whose `{active, once}` ran out never sees them when it re-arms.
class ErxGenTcpCoreTest < Minitest::Test
  include ErxNetEunit

  HALF_TARGET = 'Short >= Target div 2 orelse Waits'
  WHOLE_TARGET = 'Short >= Target orelse Waits'
  END_WAITS = "%% Passive after an error: the connection is gone, and the end waits for the owner.\n    close_out(C, Acts)."
  END_DROPPED = "%% Passive after an error: the connection is gone, and the end waits for the owner.\n    close_out(discard(C#core{ended = none}), Acts)."

  def test_socket_protocol_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_gen_tcp_core_tests)
  end

  def test_an_end_dropped_in_passive_mode_is_caught
    output = refute_erx_net_eunit(:erx_gen_tcp_core_tests, fault: { 'erx_gen_tcp_core' => [END_WAITS, END_DROPPED] })
    assert_match(/once_spent_error/, output)
  end

  def test_a_grant_only_at_the_whole_target_is_caught
    output = refute_erx_net_eunit(:erx_gen_tcp_core_tests, fault: { 'erx_gen_tcp_core' => [HALF_TARGET, WHOLE_TARGET] })
    assert_match(/credit_at_half_target/, output)
  end
end
