# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of erx_net_input (test/erlang/erx_net_input_tests.erl): one per row of
# the design's "Classifying a frame" verdict table, each frame classified with its network sum
# and without one, and those of erx_net_sum (test/erlang/erx_net_sum_tests.erl); and requires
# seeded faults, each aimed at a real break of the classification or of the sums, to fail their
# cases.
class ErxNetInputTest < Minitest::Test
  include ErxNetEunit

  # Each fault: the module, its exact text, the faulty text, and the case that must fail.
  SEEDED = {
    listener_ignores_the_link_cast: [
      'erx_net_input', '{ok, Entry} when LinkCast =:= unicast,', '{ok, Entry} when LinkCast =/= none,',
      'tcp_to_a_listener_by_link_broadcast_is_dropped_test'
    ],
    listener_ignores_the_ip_cast: [
      'erx_net_input', 'LinkCast =:= unicast, Cast =:= unicast ->', 'LinkCast =:= unicast, Cast =/= none ->',
      'tcp_to_a_listener_at_a_broadcast_address_is_dropped_test'
    ],
    segment_hard_wired_to_unicast: [
      'erx_net_input', 'ecn(Head), maps:get(link, Head)}', 'ecn(Head), unicast}',
      'tcp_to_a_connection_by_link_broadcast_carries_the_cast_test'
    ],
    udp_looked_up_without_the_address: [
      'erx_net_input', '{udp, Family, Dst, Dport}, {udp, Family, any, Dport}]',
      '{udp, Family, any, Dport}, {udp, Family, any, Dport}]', 'udp_to_the_holders_is_owned_test'
    ],
    echo_reply_taken_by_any_echo_socket: [
      'erx_net_input', "Id:16, _Seq:16, _/binary>> = Upper, \#{demux := Demux}) ->\n    case Demux({icmp_echo, inet, Id})",
      "_Id:16, _Seq:16, _/binary>> = Upper, \#{demux := Demux}) ->\n    case Demux({icmp_echo, inet, 16#e1})",
      'icmp_echo_reply_is_owned_by_its_identifier_test'
    ],
    ip6_sum_without_the_extension_headers: [
      'erx_net_input', '?IP6_HDR_LEN + HdrLen);', '?IP6_HDR_LEN + 0 * HdrLen);',
      'network_sum_behind_an_ip6_extension_header_test'
    ],
    span_keeps_the_padding: [
      'erx_net_sum', 'at(Start + Length, erx_bytes:inet_csum(0, After))', 'at(Start + Length, 0 * byte_size(After))',
      'network_sum_behind_ip4_options_and_padding_test'
    ],
    span_padding_from_an_odd_offset_unswapped: [
      'erx_net_sum', 'at(_, Sum) -> (Sum bsr 8) bor ((Sum band 16#ff) bsl 8).', 'at(_, Sum) -> Sum.',
    'span_after_an_odd_length_test'
  ],
  udp_datagram_sum_not_cut: [
    'erx_udp_wire', 'datagram_sum(Bytes, Sum, Ulen) -> erx_net_sum:span(Bytes, Sum, 0, Ulen).',
    'datagram_sum(_, Sum, _) -> Sum.', 'network_sum_of_a_udp_datagram_cut_at_its_length_test'
  ],
  icmp4_zero_field_taken_from_the_sum: [
    'erx_icmp4_wire', "checked(<<_:16, 0:16, _/binary>> = Message, _) -> erx_bytes:inet_csum(0, Message);\n", '',
    'network_sum_of_an_all_zero_icmp_message_test'
  ]
}.freeze

  def test_classification_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_input_tests, :erx_net_sum_tests)
  end

  SEEDED.each do |name, (mod, exact, faulty, failing)|
    define_method("test_seeded_#{name}_is_caught") do
      output = refute_erx_net_eunit(:erx_net_input_tests, :erx_net_sum_tests, fault: { mod => [exact, faulty] })
      assert_match(/#{failing}/, output)
    end
  end
end
