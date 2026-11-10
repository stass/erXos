# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the send log's and the default loss module's EUnit cases,
# test/erlang/erx_tcp_sendlog_tests.erl and erx_tcp_loss_dupack_tests.erl. Then
# runs the send log's again over a copy of erx_tcp_sendlog seeded with a fault,
# IsLost's byte threshold taken as "at least" instead of "more than", which the
# byte-map property must catch (docs/design-network-stack.md, "The send log,
# loss and congestion: properties and a FreeBSD oracle"), and over copies seeded
# with the faults of the runs property (docs/design-network-fastpath.md,
# Verification, test 3): a SACK block that splits a segment, the extension rule
# taking a range of another segment size, a block marking a segment it covers in
# part.
class ErxTcpLossTest < Minitest::Test
  include ErxNetEunit

  MORE_THAN = 'Runs >= DupThresh orelse Above > Limit'
  AT_LEAST = 'Runs >= DupThresh orelse Above >= Limit'

  def test_send_log_and_loss_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_sendlog_tests, :erx_tcp_loss_dupack_tests)
  end

  def test_property_catches_a_wrong_is_lost
    output = refute_erx_net_eunit(:erx_tcp_sendlog_tests, fault: { 'erx_tcp_sendlog' => [MORE_THAN, AT_LEAST] })
    assert_match(/matches_byte_map_test/, output)
  end

  SPLITS_A_SEGMENT = ['Low = Start + ceil_div(max(From - Start, 0), Seg) * Seg,',
                      'Low = max(From, Start),'].freeze
  EXTENDS_ANOTHER_SIZE = ['{Start, #sent{next = Max, seg = Seg, sent_at = Now, transmissions = 1,',
                          '{Start, #sent{next = Max, sent_at = Now, transmissions = 1,'].freeze
  MARKS_A_PART = ['false -> Start + ((To - Start) div Seg) * Seg',
                  'false -> Start + ceil_div(To - Start, Seg) * Seg'].freeze

  [[:splits_a_segment, SPLITS_A_SEGMENT], [:extends_another_size, EXTENDS_ANOTHER_SIZE],
   [:marks_a_part, MARKS_A_PART]].each do |name, fault|
    define_method(:"test_runs_property_catches_one_that_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_sendlog_tests, fault: { 'erx_tcp_sendlog' => fault })
      assert_match(/runs_keep_segments_test/, output)
    end
  end
end
