# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of erx_net_input (test/erlang/erx_net_input_tests.erl): one per row of
# the design's "Classifying a frame" verdict table; and requires four seeded faults, each aimed
# at a real break of the classification, to fail their cases.
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
    ]
  }.freeze

  def test_classification_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_input_tests)
  end

  SEEDED.each do |name, (mod, exact, faulty, failing)|
    define_method("test_seeded_#{name}_is_caught") do
      output = refute_erx_net_eunit(:erx_net_input_tests, fault: { mod => [exact, faulty] })
      assert_match(/#{failing}/, output)
    end
  end
end
