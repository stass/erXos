# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of TCP output (test/erlang/erx_tcp_output_tests.erl): windows, Nagle,
# silly-window avoidance, persist, FIN and RST, SACK retransmission, options, credit and a
# missing route, with seeded faults that settle a lost segment's ACK or D-SACK block as if it
# had left, or clear the ACK an ENOBUFS pass owes.
class ErxTcpOutputTest < Minitest::Test
  include ErxNetEunit

  # A segment lost for want of a route settles nothing (tcp_output.c:1722-1735).
  LOST = "sent({error, _}, _, _, Tcb) ->\n    Tcb."

  # Each fault: the module's exact text, the faulty text, and the case that must fail.
  SEEDED = {
    # tcp_output.c:1722-1735: only a segment that left settles the pending ACK.
    ack_settled_without_a_route: [LOST, "sent({error, _}, _, _, Tcb) ->\n    Tcb#tcb{ack_now = false}.",
                                  'no_route_keeps_the_ack_owed'],
    # tcp_output.c:1711-1714: the end of a pass clears no owed ACK, ENOBUFS included.
    ack_cleared_after_enobufs: ["Tcb#tcb{force_data = false, allowance = none}.\n",
                                "Tcb#tcb{force_data = false, allowance = none, ack_now = false}.\n",
                                'enobufs_keeps_the_ack_owed'],
    # tcp_output.c:1635-1641: only a segment that left clears the D-SACK block.
    dsack_cleared_without_a_route: [LOST, "sent({error, _}, _, RcvSack, Tcb) ->\n    Tcb#tcb{rcv_sack = RcvSack}.",
                                    'no_route_keeps_the_dsack_block']
  }.freeze

  def test_output_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_output_tests, extra: [:erx_tcp_loss_spy])
  end

  SEEDED.each do |name, (exact, faulty, failing)|
    define_method("test_seeded_#{name}_is_caught") do
      output = refute_erx_net_eunit(:erx_tcp_output_tests, fault: { 'erx_tcp_output' => [exact, faulty] },
                                                     extra: [:erx_tcp_loss_spy])
      assert_match(/#{failing}/, output)
    end
  end
end
