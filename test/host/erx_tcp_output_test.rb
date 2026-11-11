# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of TCP output (test/erlang/erx_tcp_output_tests.erl): windows, Nagle,
# silly-window avoidance, persist, FIN and RST, SACK retransmission, options, send-buffer
# autosizing, credit and a missing route, with seeded faults that settle a lost segment's ACK
# or D-SACK block as if it had left, or clear the ACK an ENOBUFS pass owes, or move
# autosizing's bounds.
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
                                    'no_route_keeps_the_dsack_block'],
    # Runs (docs/design-network-fastpath.md, "Output makes runs"): each fault makes a run's
    # frames differ from per-segment output's, which the differential case compares.
    run_drops_its_last_byte: ['Len = N * Size,', 'Len = N * Size - 1,',
                              'runs_equal_per_segment_output'],
    run_loses_its_fin: ["true -> Flags0;\n", "true -> Flags0 band bnot ?TH_FIN;\n",
                        'runs_equal_per_segment_output'],
    options_only_in_the_first_frame: ['| cut(Header#tcp{seq = erx_tcp_seq:wire(Seq + Seg)}, Marks',
                                      '| cut(Header#tcp{seq = erx_tcp_seq:wire(Seq + Seg), opts = #tcp_opts{}}, Marks',
                                      'runs_equal_per_segment_output'],
    sequence_not_advanced_per_frame: ['cut(Header#tcp{seq = erx_tcp_seq:wire(Seq + Seg)}',
                                      'cut(Header#tcp{seq = Seq}', 'runs_equal_per_segment_output'],
    run_with_sack_blocks: ['andalso Sacks =:= [] andalso Up =< Nxt', 'andalso is_list(Sacks) andalso Up =< Nxt',
                           'runs_equal_per_segment_output'],
    run_takes_one_unit_of_credit: ['{Credit - Frames, Runs}', '{Credit - min(Frames, 1), Runs}',
                                   'runs_equal_per_segment_output'],
    run_in_recovery: ['Source =:= next andalso not Fast', 'Source =:= next andalso is_boolean(Fast)',
                      'runs_equal_per_segment_output'],
    run_without_a_route: ['Route =:= ok andalso erx_tcp:have_established(State)',
                          'is_tuple(Route) andalso erx_tcp:have_established(State)',
                          'runs_equal_per_segment_output'],
    # A run over more binaries than the C cut walks, which the tap NIF refuses with badarg.
    run_past_its_64th_binary: ['payload(Seg, Want, ?RUN_PIECES, Tcb)', 'payload(Seg, Want, infinity, Tcb)',
                               'run_ends_at_its_64th_binary'],
    # One binary past the bound: the exact case sees a run of 65 binaries.
    run_bound_off_by_one: ['payload(Seg, Want, ?RUN_PIECES, Tcb)', 'payload(Seg, Want, ?RUN_PIECES + 1, Tcb)',
                           'run_bound_is_exact'],
    run_with_cwr: ['andalso ecn_steady(ecn(Seg, Tcb), Flags, Ecn).', 'andalso (ecn_steady(ecn(Seg, Tcb), Flags, Ecn) orelse true).',
                   'runs_equal_per_segment_output'],
    # tcp_output.c:2169: a buffer exactly 7/8 full grows.
    autoscale_fill_bound_off_by_one: ['andalso Used >= Hiwat div 8 * 7', 'andalso Used > Hiwat div 8 * 7',
                                      'autoscale_grows_a_full_buffer'],
    # uipc_sockbuf.c:659: no size past sb_max_adj is asked of the grant.
    autoscale_past_sb_max_adj: ['{Grows, Bytes =< ?SB_MAX_ADJ}', '{Grows, Bytes =< ?AUTOSNDBUF_MAX}',
                                'autoscale_stops_at_the_largest_buffer']
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
